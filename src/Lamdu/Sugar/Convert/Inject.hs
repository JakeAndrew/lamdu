{-# LANGUAGE NoImplicitPrelude #-}
module Lamdu.Sugar.Convert.Inject
    ( convert
    ) where

import qualified Control.Lens as Lens
import qualified Lamdu.Calc.Val as V
import           Lamdu.Calc.Val.Annotated (Val)
import qualified Lamdu.Expr.Lens as ExprLens
import qualified Lamdu.Expr.UniqueId as UniqueId
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

convert :: (Monad m, Monoid a) => V.Inject (Val (Input.Payload m a)) -> Input.Payload m a -> ConvertM m (ExpressionU m a)
convert (V.Inject tag val) exprPl =
    -- TODO: Lots of duplication here from getField, generalize both!
    Inject
    { _iMVal = mVal
    , _iTag =
        Tag
        { _tagInfo =
            TagInfo
            { _tagInstance = EntityId.ofInjectTag entityId
            , _tagVal = tag
            }
        , _tagName = UniqueId.toUUID tag
        , _tagActions = error "TODO: tagActions. need to think of UI if this should be exposed here.."
        }
    }
    & traverse ConvertM.convertSubexpression
    <&> BodyInject
    >>= addActions exprPl
    where
        isNullary = Lens.has ExprLens.valRecEmpty val
        entityId = exprPl ^. Input.entityId
        mVal
            | isNullary = Nothing
            | otherwise = Just val
