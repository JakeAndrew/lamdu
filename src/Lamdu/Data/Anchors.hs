{-# LANGUAGE NoImplicitPrelude, Rank2Types, OverloadedStrings, DeriveGeneric, TemplateHaskell, GeneralizedNewtypeDeriving #-}
module Lamdu.Data.Anchors
    ( Code(..), onCode
    , Revision(..), onRevision
    , Pane(..)
    , CodeAnchors, RevisionProps
    , assocNameRef
    , assocScopeRef
    , PresentationMode(..), assocPresentationMode
    , DefinitionState(..), assocDefinitionState
    , assocTagOrder
    , ParamList
    , assocFieldParamList
    , BinderParamScopeId(..), bParamScopeId
    ) where

import qualified Control.Lens as Lens
import           Data.Binary (Binary)
import           Data.ByteString.Char8 ()
import           Data.Store.Rev.Branch (Branch)
import           Data.Store.Rev.Version (Version)
import           Data.Store.Rev.View (View)
import           Data.Store.Transaction (MkProperty(..))
import qualified Data.Store.Transaction as Transaction
import           GHC.Generics (Generic)
import qualified GUI.Momentu.Widget.Id as WidgetId
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Definition as Definition
import           Lamdu.Eval.Results (ScopeId)
import           Lamdu.Expr.IRef (DefI, ValI)
import qualified Lamdu.Expr.UniqueId as UniqueId

import           Lamdu.Prelude

newtype Pane m = Pane
    { paneDef :: DefI m
    } deriving (Eq, Ord, Show, Generic)
instance Binary (Pane m)

data Code f m = Code
    { repl :: f (Definition.Expr (ValI m))
    , panes :: f [Pane m]
    , globals :: f (Set (DefI m))
    , preJumps :: f [WidgetId.Id]
    , preCursor :: f WidgetId.Id
    , postCursor :: f WidgetId.Id
    , tags :: f (Set T.Tag)
    , tids :: f (Set T.NominalId)
    }
onCode :: (forall a. Binary a => f a -> g a) -> Code f m -> Code g m
onCode f (Code x0 x1 x2 x3 x4 x5 x6 x7) =
    Code (f x0) (f x1) (f x2) (f x3) (f x4) (f x5) (f x6) (f x7)

data Revision f m = Revision
    { branches :: f [Branch m]
    , currentBranch :: f (Branch m)
    , redos :: f [Version m]
    , view :: f (View m)
    }
onRevision :: (forall a. Binary a => f a -> g a) -> Revision f m -> Revision g m
onRevision f (Revision x0 x1 x2 x3) =
    Revision (f x0) (f x1) (f x2) (f x3)

newtype BinderParamScopeId = BinderParamScopeId
    { _bParamScopeId :: ScopeId
    } deriving (Eq, Ord, Binary)

type CodeAnchors m = Code (MkProperty m) m
type RevisionProps m = Revision (MkProperty m) m

assocNameRef :: (UniqueId.ToUUID a, Monad m) => a -> MkProperty m Text
assocNameRef = Transaction.assocDataRefDef "" "Name" . UniqueId.toUUID

assocScopeRef ::
    (UniqueId.ToUUID a, Monad m) => a -> MkProperty m (Maybe BinderParamScopeId)
assocScopeRef = Transaction.assocDataRef "ScopeId" . UniqueId.toUUID

assocTagOrder :: Monad m => T.Tag -> MkProperty m Int
assocTagOrder = Transaction.assocDataRefDef 0 "Order" . UniqueId.toUUID

type ParamList = [T.Tag]

assocFieldParamList ::
    Monad m => ValI m -> Transaction.MkProperty m (Maybe ParamList)
assocFieldParamList lambdaI =
    Transaction.assocDataRef "field param list" $ UniqueId.toUUID lambdaI

data PresentationMode
    = OO T.Tag
    | Verbose
    | Infix T.Tag T.Tag
    deriving (Eq, Ord, Show, Generic)
instance Binary PresentationMode

assocPresentationMode ::
    (UniqueId.ToUUID a, Monad m) =>
    a -> Transaction.MkProperty m PresentationMode
assocPresentationMode =
    Transaction.assocDataRefDef Verbose "PresentationMode" . UniqueId.toUUID

data DefinitionState = DeletedDefinition | LiveDefinition
    deriving (Eq, Ord, Show, Generic)
instance Binary DefinitionState

assocDefinitionState :: Monad m => DefI m -> Transaction.MkProperty m DefinitionState
assocDefinitionState =
    Transaction.assocDataRefDef LiveDefinition "DefinitionState" . UniqueId.toUUID

Lens.makeLenses ''BinderParamScopeId
