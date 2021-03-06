{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Precedence
    ( Precedence(..), make
    , MyPrecedence(..), my
    , ParentPrecedence(..), parent
    , needParens
    , before, after
    ) where

import qualified Control.Lens as Lens

data Precedence = Precedence
    { _before :: {-# UNPACK #-}!Int
    , _after  :: {-# UNPACK #-}!Int
    } deriving Show

Lens.makeLenses ''Precedence

make :: Int -> Precedence
make p = Precedence p p

newtype MyPrecedence = MyPrecedence Precedence deriving Show
newtype ParentPrecedence = ParentPrecedence Precedence deriving Show

parent :: Int -> ParentPrecedence
parent = ParentPrecedence . make

my :: Int -> MyPrecedence
my = MyPrecedence . make

needParens :: ParentPrecedence -> MyPrecedence -> Bool
needParens (ParentPrecedence x) (MyPrecedence y) =
    _before x > _before y || _after x > _after y
