{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2017  Markus Ongyerth

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

Reach us at https://github.com/ongy/waymonad
-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
module ViewSet
where

import Data.Foldable (toList)
import Data.List (find)
import Data.Map (Map)
import Data.Maybe (listToMaybe, isJust)
import Data.Text (Text)
import Data.Typeable
import Graphics.Wayland.WlRoots.Box (boxContainsPoint, Point (..), WlrBox (..))

import Input.Seat (Seat)
import View (View)

import qualified Data.Text as T

type ViewSet a = Map a Workspace

newtype Zipper a b = Zipper [(Maybe a {- This is probably going to become a List or Set in the near-ish future -}, b)]
    deriving (Eq, Show, Functor, Foldable, Traversable)


data Workspace = Workspace
    { wsLayout :: Layout
    , wsViews :: Maybe (Zipper (Seat) View)
    } deriving (Show)

class (Typeable a, Show a, Eq a, Ord a) => WSTag a where
    getName :: a -> Text

instance WSTag Text where
    getName = id

class LayoutClass a where
    pureLayout :: a -> WlrBox -> Zipper b c -> [(c, WlrBox)]
    handleMessage :: a -> SomeMessage -> Maybe a
    description :: a -> Text

data Layout = forall l. LayoutClass l => Layout l

instance Show Layout where
    show (Layout l) = T.unpack $ description l

class Typeable m => Message m

data SomeMessage = forall m. Message m => SomeMessage m

getMessage :: Message m => SomeMessage -> Maybe m
getMessage (SomeMessage m) = cast m

messageWS :: SomeMessage -> Workspace -> Workspace
messageWS m w@(Workspace (Layout l) z) =
    case handleMessage l  m of
        Nothing -> w
        Just nl -> Workspace (Layout nl) z

getMaster :: Workspace -> Maybe View
getMaster (Workspace _ z) = getMaster' =<< z

getMaster' :: Zipper a b -> Maybe b
getMaster' (Zipper xs) =  snd <$> listToMaybe xs

setFocused :: View -> Seat -> Workspace -> Workspace
setFocused v t (Workspace l z) =
    Workspace l $ fmap (setFocused' t v) z

getFocused :: Seat -> Workspace -> Maybe View
getFocused seat (Workspace _ (Just (Zipper z))) =
    fmap snd $ find ((==) (Just seat) . fst) z
getFocused _ _ = Nothing

getFirstFocused :: Workspace -> Maybe View
getFirstFocused (Workspace _ z) = getFirstFocused' =<< z

getFirstFocused' :: Zipper a b -> Maybe b
getFirstFocused' (Zipper z) =
    fmap snd $ find (isJust . fst) z

addView :: Maybe (Seat) -> View -> Workspace -> Workspace
addView seat v (Workspace l z) = Workspace l $ addElem seat v z

rmView :: View -> Workspace -> Workspace
rmView v (Workspace l z) = Workspace l $ rmElem v z

viewBelow
    :: Traversable t
    => Point
    -> t (View, WlrBox)
    -> IO (Maybe (View, Int, Int))
viewBelow point views = do
    let candidates = filter (boxContainsPoint point . snd) $ toList views
    pure . fmap (uncurry makeLocal) . listToMaybe $ candidates
    where   makeLocal :: View -> WlrBox -> (View, Int, Int)
            makeLocal view (WlrBox x y _ _) =
                (view, pointX point - x, pointY point - y)

-- TODO: Refactor :(
setFocused' :: (Eq a, Eq b) => a -> b -> Zipper a b -> Zipper a b
setFocused' t v (Zipper xs) =
    Zipper $ map update xs
    where   update orig@(ot, x) = if x == v
                then (Just t, x)
                else if ot == Just t
                    then (Nothing, x)
                    else orig

addElem' :: Eq a => Maybe a -> Maybe (Zipper a b) -> b -> Zipper a b
addElem' t Nothing v = Zipper [(t, v)]
addElem' Nothing (Just (Zipper xs)) v = Zipper $ (Nothing, v) : xs
addElem' (Just t) (Just (Zipper xs)) v = 
    let pre = takeWhile ((/=) (Just t) . fst) xs
        pos = dropWhile ((/=) (Just t) . fst) xs
     in Zipper $ case pos of
            [] -> (Just t, v) : pre
            ((_, c):ys) -> pre ++ (Just t, v) : (Nothing, c) : ys

-- This asumes the element is in the zipper only once!
rmElem' :: Eq a => a -> Zipper b a -> Maybe (Zipper b a)
rmElem' y z@(Zipper [(_, x)]) = if x == y
    then Nothing
    else Just z
rmElem' y z@(Zipper xs) =
    let pre = takeWhile ((/=) y . snd) xs
        pos = dropWhile ((/=) y . snd) xs
     in Just $ case pos of
            [] -> z
            ((Nothing, _):ys) -> Zipper $ pre ++ ys
            [(Just t, _)] -> Zipper $ (Just t, snd $ head pre) : tail pre
            ((Just t, _):ys) -> Zipper $ pre ++ (Just t, snd $ head ys) : tail ys

addElem :: Eq a => Maybe a -> b -> Maybe (Zipper a b) -> Maybe (Zipper a b)
addElem t v z = Just $ addElem' t z v

rmElem :: Eq a => a -> Maybe (Zipper b a) -> Maybe (Zipper b a)
rmElem v z = rmElem' v =<< z

contains :: Eq a => a -> Zipper b a -> Bool
contains x (Zipper xs) = elem x $ map snd xs

snoc :: a -> [a] -> [a]
snoc x xs = xs ++ [x]

moveRight :: (Seat) -> Workspace -> Workspace
moveRight t (Workspace l z) = Workspace l $ fmap (moveRight' t) z

moveRight' :: Eq a => a -> Zipper a b -> Zipper a b
moveRight' _ z@(Zipper [_]) = z
moveRight' t (Zipper xs) =
    let pre = takeWhile ((/=) (Just t) . fst) xs
        pos = dropWhile ((/=) (Just t) . fst) xs
     in Zipper $ case pos of
            [] -> (Just t, snd $ head xs) : tail xs
            [(Just _, c)] -> (Just t, snd $ head pre) : tail pre ++ [(Nothing, c)]
            ((Just _, c):ys) -> pre ++ (Nothing ,c): (Just t, snd $ head ys) : tail ys

            -- This case should be impossible
            ((Nothing, _):_) -> error "moveRight hit an impossible case"

moveLeft :: Seat -> Workspace -> Workspace
moveLeft t (Workspace l z) = Workspace l $ fmap (moveLeft' t) z

moveLeft' :: Eq a => a -> Zipper a b -> Zipper a b
moveLeft' _ z@(Zipper [_]) = z
moveLeft' t (Zipper xs) =
    let pre = takeWhile ((/=) (Just t) . fst) xs
        pos = dropWhile ((/=) (Just t) . fst) xs
     in Zipper $ case pre of

            [] -> (Nothing, snd $ head xs) : init (tail xs) ++ [(Just t, snd $ last xs)]
            [(Nothing, c)] -> (Just t, c) : (Nothing, snd $ head pos) : tail pos
            ys -> init ys ++ (Just t, snd $ last ys) : case pos of
                ((_, z):zs) -> (Nothing, z) : zs
                [] -> []

moveViewLeft :: Seat -> Workspace -> Workspace
moveViewLeft t (Workspace l z) = Workspace l $ fmap (moveElemLeft' t) z

moveElemLeft' :: Eq a => a -> Zipper a b -> Zipper a b
moveElemLeft' _ z@(Zipper [_]) = z
moveElemLeft' t (Zipper xs) =
    let pre = takeWhile ((/=) (Just t) . fst) xs
        pos = dropWhile ((/=) (Just t) . fst) xs
     in Zipper $ case pre of
        [] -> snoc (head pos) (tail pos)
        ys -> case pos of
            [] -> ys
            (z:zs) ->  let left = last ys
                        in (init ys) ++ z : left : zs

moveViewRight :: Seat -> Workspace -> Workspace
moveViewRight t (Workspace l z) = Workspace l $ fmap (moveElemRight' t) z

moveElemRight' :: Eq a => a -> Zipper a b -> Zipper a b
moveElemRight' _ z@(Zipper [_]) = z
moveElemRight' t (Zipper xs) =
    let pre = takeWhile ((/=) (Just t) . fst) xs
        pos = dropWhile ((/=) (Just t) . fst) xs
     in Zipper $ case pos of
        [] -> xs -- We didn't find a focused view
        (y:ys) -> case ys of
            [] -> y : pre
            (z:zs) ->  pre ++ z : y : zs
