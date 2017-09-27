{-# LANGUAGE NoImplicitPrelude #-}
module Lamdu.Sugar.PresentationModes
    ( addToDef, addToExpr
    ) where

import qualified Control.Lens as Lens
import           Data.Either (partitionEithers)
import qualified Data.Map as Map
import           Data.UUID.Types (UUID)
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction

addToLabeledApply ::
    Monad m =>
    Sugar.LabeledApply UUID f (Sugar.Expression UUID f a) ->
    T m (Sugar.LabeledApply UUID f (Sugar.Expression UUID f a))
addToLabeledApply a =
    case a ^. Sugar.aSpecialArgs of
    Sugar.NoSpecialArgs ->
        do
            presentationMode <-
                a ^. Sugar.aFunc . Sugar.bvNameRef . Sugar.nrName
                & Anchors.assocPresentationMode & Transaction.getP
            let (specialArgs, otherArgs) =
                    case presentationMode of
                    Sugar.Infix l r ->
                        ( Sugar.InfixArgs (mkInfixArg la ra) (mkInfixArg ra la)
                        , argsMap
                            & Map.delete l
                            & Map.delete r
                            & Map.elems
                        )
                        where
                            la = argExpr l
                            ra = argExpr r
                    Sugar.OO o ->
                        ( Sugar.ObjectArg (argExpr o)
                        , Map.delete o argsMap & Map.elems
                        )
                    _ -> (Sugar.NoSpecialArgs, a ^. Sugar.aAnnotatedArgs)
            let (annotatedArgs, relayedArgs) = otherArgs <&> processArg & partitionEithers
            a
                & Sugar.aSpecialArgs .~ specialArgs
                & Sugar.aAnnotatedArgs .~ annotatedArgs
                & Sugar.aRelayedArgs .~ relayedArgs
                & return
    _ -> return a
    where
        argsMap =
            a ^. Sugar.aAnnotatedArgs
            <&> (\x -> (x ^. Sugar.aaTag . Sugar.tagVal, x))
            & Map.fromList
        argExpr t = argsMap Map.! t ^. Sugar.aaExpr
        mkInfixArg arg other =
            arg
            & Sugar.rBody . Sugar._BodyHole . Sugar.holeActions . Sugar.holeMDelete .~
                other ^. Sugar.rPayload . Sugar.plActions . Sugar.mReplaceParent
        processArg arg =
            do
                param <- arg ^? Sugar.aaExpr . Sugar.rBody . Sugar._BodyGetVar . Sugar._GetParam
                param ^. Sugar.pNameRef . Sugar.nrName == arg ^. Sugar.aaName & guard
                Right Sugar.RelayedArg
                    { Sugar._raValue = param
                    , Sugar._raId = arg ^. Sugar.aaExpr . Sugar.rPayload . Sugar.plEntityId
                    , Sugar._raActions = arg ^. Sugar.aaExpr . Sugar.rPayload . Sugar.plActions
                    } & return
            & fromMaybe (Left arg)

addToHoleResult ::
    Monad m =>
    Sugar.HoleResult m (Sugar.Expression UUID m ()) ->
    T m (Sugar.HoleResult m (Sugar.Expression UUID m ()))
addToHoleResult = Sugar.holeResultConverted %%~ addToExpr

addToHole ::
    Monad m =>
    Sugar.Hole m (Sugar.Expression UUID m ()) a -> Sugar.Hole m (Sugar.Expression UUID m ()) a
addToHole =
    Sugar.holeActions . Sugar.holeOptions .
    Lens.mapped . Lens.mapped . Sugar.hoResults . Lens.mapped .
    _2 %~ (>>= addToHoleResult)

addToBody ::
    Monad m =>
    Sugar.Body UUID m (Sugar.Expression UUID m a) ->
    T m (Sugar.Body UUID m (Sugar.Expression UUID m a))
addToBody (Sugar.BodyLabeledApply a) = addToLabeledApply a <&> Sugar.BodyLabeledApply
addToBody (Sugar.BodyHole a) = addToHole a & Sugar.BodyHole & return
addToBody b = return b

addToExpr :: Monad m => Sugar.Expression UUID m pl -> T m (Sugar.Expression UUID m pl)
addToExpr e =
    e
    & Sugar.rBody %%~ addToBody
    >>= Sugar.rBody . Lens.traversed %%~ addToExpr

addToBinder ::
    Monad m =>
    Sugar.Binder UUID m (Sugar.Expression UUID m pl) ->
    T m (Sugar.Binder UUID m (Sugar.Expression UUID m pl))
addToBinder = Sugar.bBody %%~ addToBinderBody

addToBinderBody ::
    Monad m =>
    Sugar.BinderBody UUID m (Sugar.Expression UUID m pl) ->
    T m (Sugar.BinderBody UUID m (Sugar.Expression UUID m pl))
addToBinderBody = Sugar.bbContent %%~ addToBinderContent

addToBinderContent ::
    Monad m =>
    Sugar.BinderContent UUID m (Sugar.Expression UUID m pl) ->
    T m (Sugar.BinderContent UUID m (Sugar.Expression UUID m pl))
addToBinderContent (Sugar.BinderExpr e) = addToExpr e <&> Sugar.BinderExpr
addToBinderContent (Sugar.BinderLet l) = addToLet l <&> Sugar.BinderLet

addToLet ::
    Monad m =>
    Sugar.Let UUID m (Sugar.Expression UUID m pl) ->
    T m (Sugar.Let UUID m (Sugar.Expression UUID m pl))
addToLet letItem =
    letItem
    & Sugar.lValue %%~ addToBinder
    >>= Sugar.lBody %%~ addToBinderBody

addToDef ::
    Monad m =>
    Sugar.Definition UUID m (Sugar.Expression UUID m a) ->
    T m (Sugar.Definition UUID m (Sugar.Expression UUID m a))
addToDef def =
    def
    & Sugar.drBody . Sugar._DefinitionBodyExpression .
      Sugar.deContent %%~ addToBinder
