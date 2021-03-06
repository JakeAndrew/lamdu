{-# LANGUAGE NoImplicitPrelude #-}
module Lamdu.GUI.ExpressionEdit.HoleEdit.Info
    ( HoleInfo(..)
    , hiSearchTermProperty
    , hiSearchTerm
    ) where

import           Data.Store.Property (Property(..))
import qualified Data.Store.Property as Property
import qualified Data.Store.Transaction as Transaction
import           Lamdu.Calc.Type (Type)
import           Lamdu.GUI.ExpressionEdit.HoleEdit.State (HoleState, hsSearchTerm)
import           Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds (WidgetIds)
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import           Lamdu.Sugar.Names.Types (Name)
import           Lamdu.Sugar.NearestHoles (NearestHoles)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction.Transaction

data HoleInfo m = HoleInfo
    { hiEntityId :: Sugar.EntityId
    , hiInferredType :: Type
    , hiIds :: WidgetIds
    , hiHole :: Sugar.Hole m (Sugar.Expression (Name m) m ()) (ExprGuiT.SugarExpr m)
    , hiNearestHoles :: NearestHoles
    , hiState :: Property (T m) HoleState
    }

hiSearchTermProperty :: HoleInfo m -> Property (T m) Text
hiSearchTermProperty holeInfo = hiState holeInfo & Property.composeLens hsSearchTerm

hiSearchTerm :: HoleInfo m -> Text
hiSearchTerm holeInfo = hiState holeInfo ^. Property.pVal . hsSearchTerm
