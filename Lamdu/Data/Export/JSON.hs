-- | Import/Export JSON support
{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, OverloadedStrings, FlexibleContexts, LambdaCase #-}
module Lamdu.Data.Export.JSON
    ( exportRepl
    , importAll
    ) where

-- TODO: Assoc data?
-- TODO: Schema version? What granularity?

import qualified Control.Lens as Lens
import           Control.Lens.Operators hiding ((.=))
import           Control.Lens.Tuple
import           Control.Monad (unless)
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.State (StateT)
import qualified Control.Monad.Trans.State as State
import           Control.Monad.Trans.Writer (WriterT(..))
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.Aeson.Encode.Pretty as AesonPretty
import           Data.Binary (Binary)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import           Data.Either.Combinators (swapEither)
import           Data.Foldable (traverse_)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Store.IRef (IRef)
import qualified Data.Store.IRef as IRef
import qualified Data.Store.Property as Property
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import           Data.UUID.Types (UUID)
import qualified Lamdu.Data.Anchors as Anchors
import           Lamdu.Data.DbLayout (ViewM)
import qualified Lamdu.Data.DbLayout as DbLayout
import           Lamdu.Data.Definition (Definition(..))
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.Data.Export.JSON.Codec as Codec
import           Lamdu.Expr.IRef (ValI)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Lens as ExprLens
import qualified Lamdu.Expr.Load as Load
import           Lamdu.Expr.Nominal (Nominal)
import qualified Lamdu.Expr.Type as T
import           Lamdu.Expr.UniqueId (ToUUID)
import           Lamdu.Expr.Val (Val(..))
import qualified Lamdu.Expr.Val as V

import           Prelude.Compat

type T = Transaction

replIRef :: IRef ViewM (ValI ViewM)
replIRef = DbLayout.repl DbLayout.codeIRefs


data Visited = Visited
    { _visitedDefs :: Set V.Var
    , _visitedTags :: Set T.Tag
    , _visitedNominals :: Set T.NominalId
    }
Lens.makeLenses ''Visited

type Export = WriterT [Codec.Encoded] (StateT Visited (T ViewM))

runExport :: Export a -> T ViewM (a, Codec.Encoded)
runExport act =
    act
    & runWriterT
    <&> _2 %~ Codec.encodeArray
    & (`State.evalStateT` Visited mempty mempty mempty)

trans :: T ViewM a -> Export a
trans = lift . lift

withVisited :: Ord a => Lens.ALens' Visited (Set a) -> a -> Export () -> Export ()
withVisited l x act =
    do
        alreadyVisited <- Lens.use (Lens.cloneLens l . Lens.contains x)
        unless alreadyVisited $
            do
                Lens.assign (Lens.cloneLens l . Lens.contains x) True
                act

readAssocName :: ToUUID a => a -> Export (Maybe String)
readAssocName x =
    do
        name <- Anchors.assocNameRef x & Transaction.getP & trans
        return $
            if null name
            then Nothing
            else Just name

tell :: Codec.Encoded -> Export ()
tell = Writer.tell . (: [])

exportTag :: T.Tag -> Export ()
exportTag tag =
    do
        mName <- readAssocName tag
        Codec.encodeNamedTag (mName, tag) & tell
    & withVisited visitedTags tag

exportNominal :: T.NominalId -> Export ()
exportNominal nomId =
    trans (Load.nominal nomId) >>=
    \case
    Nothing -> return ()
    Just nominal ->
        do
            mName <- readAssocName nomId
            Codec.encodeNamedNominal ((mName, nomId), nominal) & tell
        & withVisited visitedNominals nomId

recurse :: Val a -> Export ()
recurse val =
    do
        -- TODO: Add a recursion on all ExprLens.subExprs -- that have
        -- a Lam inside them, on the "Var" to export all the var names
        -- too?  OR: alternatively, remove the "name" crap and just
        -- add the set of all UUIDs we ever saw to the WriterT, and
        -- export all associated names/data of all!
        val ^.. ExprLens.valGlobals mempty & traverse_ exportDef
        val ^.. ExprLens.valTags & traverse_ exportTag
        val ^.. ExprLens.valNominals & traverse_ exportNominal

valIToUUID :: ValI m -> UUID
valIToUUID = IRef.uuid . ExprIRef.unValI

exportDef :: V.Var -> Export ()
exportDef globalId =
    do
        mName <- readAssocName globalId
        def <-
            ExprIRef.defI globalId & Load.def & trans
            <&> Definition.defBody . Lens.mapped . Lens.mapped %~
            valIToUUID . Property.value
        traverse_ recurse (def ^. Definition.defBody)
        (mName, globalId) <$ def & Codec.encodeDef & tell
    & withVisited visitedDefs globalId

exportRepl :: T ViewM Codec.Encoded
exportRepl =
    do
        repl <-
            Transaction.readIRef replIRef >>= ExprIRef.readVal & trans
            <&> fmap valIToUUID
        recurse repl
        Codec.encodeRepl repl & tell
    & runExport
    <&> snd

setName :: ToUUID a => a -> String -> T ViewM ()
setName x = Transaction.setP (Anchors.assocNameRef x)

writeValAt :: Monad m => Val (ValI m) -> T m (ValI m)
writeValAt (Val valI body) =
    do
        traverse writeValAt body >>= ExprIRef.writeValBody valI
        return valI

writeValAtUUID :: Monad m => Val UUID -> T m (ValI m)
writeValAtUUID val = val <&> IRef.unsafeFromUUID <&> ExprIRef.ValI & writeValAt

insertTo ::
    (Monad m, Ord a, Binary a) =>
    a -> (DbLayout.Code (IRef ViewM) ViewM -> IRef m (Set a)) -> Transaction m ()
insertTo item setIRef =
    Transaction.readIRef iref
    <&> Set.insert item
    >>= Transaction.writeIRef iref
    where
        iref = setIRef DbLayout.codeIRefs

importDef :: Definition (Val UUID) (Maybe String, V.Var) -> T ViewM ()
importDef (Definition defBody (mName, globalId)) =
    do
        traverse_ (setName globalId) mName
        Lens.traverse writeValAtUUID defBody
            >>= Transaction.writeIRef defI
        defI `insertTo` DbLayout.globals
    where
        defI = ExprIRef.defI globalId

importRepl :: Val UUID -> T ViewM ()
importRepl val = writeValAtUUID val >>= Transaction.writeIRef replIRef

importTag :: (Maybe String, T.Tag) -> T ViewM ()
importTag (mName, tag) =
    do
        traverse_ (setName tag) mName
        tag `insertTo` DbLayout.tags

importNominal :: ((Maybe String, T.NominalId), Nominal) -> T ViewM ()
importNominal ((mName, nomId), nominal) =
    do
        traverse_ (setName nomId) mName
        Transaction.writeIRef (ExprIRef.nominalI nomId) nominal
        nomId `insertTo` DbLayout.tids

-- Like asum/msum but collects the errors
firstSuccess :: [Either err a] -> Either [err] a
firstSuccess = swapEither . sequence . fmap swapEither

importOne :: Codec.Encoded -> T ViewM ()
importOne json =
    firstSuccess
    [ try Codec.decodeDef importDef
    , try Codec.decodeRepl importRepl
    , try Codec.decodeNamedTag importTag
    , try Codec.decodeNamedNominal importNominal
    ]
    & either parseFail return
    >>= id
    where
        parseFail errors =
            "Failed to parse: " ++ BSL8.unpack (AesonPretty.encodePretty json) ++
            "\n" ++ unlines errors
            & fail
        try decode imp = Codec.runDecoder decode json <&> imp

importAll :: Codec.Encoded -> T ViewM ()
importAll json =
    Codec.runDecoder Codec.decodeArray json
    & either fail return
    >>= traverse_ importOne