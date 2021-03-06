{-# LANGUAGE LambdaCase, NoImplicitPrelude, OverloadedStrings #-}
module Lamdu.GUI.ExpressionEdit.HoleEdit.ValTerms
    ( expr
    ) where

import           Data.Store.Property (Property)
import qualified Data.Store.Property as Property
import qualified Data.Text as Text
import qualified Lamdu.Builtins.Anchors as Builtins
import           Lamdu.Formatting (Format(..))
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.Names.Get as NamesGet
import           Lamdu.Sugar.Names.Types (Name(..), Collision(..), ExpressionN)
import qualified Lamdu.Sugar.Names.Types as Name
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

collisionText :: Name.Collision -> Text
collisionText NoCollision = ""
collisionText (Collision i) = Text.pack (show i)
collisionText UnknownCollision = "?"

ofName :: Name.Form -> Text
ofName (Name.AutoGenerated text) = text
ofName (Name.Unnamed collision) = Name.unnamedText <> collisionText collision
ofName (Name.Stored name collision) = name <> collisionText collision

formatProp :: Format a => Property m a -> Text
formatProp i = i ^. Property.pVal & format

formatLiteral :: Sugar.Literal (Property m) -> Text
formatLiteral (Sugar.LiteralNum i) = formatProp i
formatLiteral (Sugar.LiteralText i) = formatProp i
formatLiteral (Sugar.LiteralBytes i) = formatProp i

bodyShape :: Sugar.Body (Name m) m expr -> [Text]
bodyShape = \case
    Sugar.BodyLam {} -> ["lambda", "\\", "Λ", "λ", "->", "→"]
    Sugar.BodySimpleApply {} -> ["Apply"]
    Sugar.BodyLabeledApply {} -> ["Apply"]
    Sugar.BodyRecord r ->
        ["record", "{}", "()"] ++
        case r of
        Sugar.Composite [] Sugar.ClosedComposite{} _ -> ["empty"]
        _ -> []
    Sugar.BodyGetField gf ->
        [".", "field", "." <> ofName (gf ^. Sugar.gfTag . Sugar.tagName . Name.form)]
    Sugar.BodyCase cas ->
        ["case", ":"] ++
        case cas of
            Sugar.Case Sugar.LambdaCase (Sugar.Composite [] Sugar.ClosedComposite{} _) -> ["absurd"]
            _ -> []
    Sugar.BodyGuard {} -> ["if", ":"]
    Sugar.BodyInject {} -> ["[]"]
    Sugar.BodyLiteral i -> [formatLiteral i]
    Sugar.BodyGetVar Sugar.GetParamsRecord {} -> ["Params"]
    Sugar.BodyGetVar {} -> []
    Sugar.BodyToNom {} -> []
    Sugar.BodyFromNom nom
        | nom ^. Sugar.nTId . Sugar.tidTId == Builtins.boolTid -> ["if"]
        | otherwise -> []
    Sugar.BodyHole {} -> []
    Sugar.BodyInjectedExpression {} -> []

bodyNames :: Monad m => Sugar.Body (Name m) m expr -> [Text]
bodyNames = \case
    Sugar.BodyGetVar Sugar.GetParamsRecord {} -> []
    Sugar.BodyLam {} -> []
    b -> NamesGet.fromBody b <&> (^. Name.form) <&> ofName

expr :: Monad m => ExpressionN m a -> [Text]
expr (Sugar.Expression body _) =
    bodyShape body <> bodyNames body <>
    case body of
    Sugar.BodyToNom (Sugar.Nominal _ binder) ->
        expr (binder ^. Sugar.bbContent . SugarLens.binderContentExpr)
    Sugar.BodyFromNom (Sugar.Nominal _ val) -> expr val
    _ -> []
