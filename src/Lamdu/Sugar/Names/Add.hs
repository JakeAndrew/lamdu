{-# LANGUAGE LambdaCase, NoImplicitPrelude, GeneralizedNewtypeDeriving, RecordWildCards, TypeFamilies, TemplateHaskell, DeriveGeneric, KindSignatures, NoMonomorphismRestriction, OverloadedStrings #-}
module Lamdu.Sugar.Names.Add
    ( addToWorkArea
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Trans.Reader (Reader, runReader)
import qualified Control.Monad.Trans.Reader as Reader
import           Control.Monad.Trans.State (runState, evalState)
import           Control.Monad.Trans.FastWriter (Writer, runWriter)
import qualified Control.Monad.Trans.FastWriter as Writer
import qualified Data.List.Utils as ListUtils
import qualified Data.Map as Map
import qualified Data.Map.Utils as MapUtils
import           Data.Monoid.Generic (def_mempty, def_mappend)
import qualified Data.Set as Set
import           Data.Set.Ordered (OrderedSet)
import qualified Data.Set.Ordered as OrderedSet
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import qualified Data.Text as Text
import           Data.UUID.Types (UUID)
import           GHC.Generics (Generic)
import           Lamdu.Data.Anchors (assocNameRef)
import qualified Lamdu.Sugar.Lens as SugarLens
import           Lamdu.Sugar.Names.CPS (CPS(..))
import           Lamdu.Sugar.Names.NameGen (NameGen)
import qualified Lamdu.Sugar.Names.NameGen as NameGen
import           Lamdu.Sugar.Names.Types
import           Lamdu.Sugar.Names.Walk (MonadNaming)
import qualified Lamdu.Sugar.Names.Walk as Walk
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

type T = Transaction
type StoredName = Text

------------------------------
---------- Pass 0 ------------
------------------------------
data P0Out = P0Out
    { _mStoredName :: Maybe StoredName
    , _mStoredUUID :: UUID
    }

newtype Pass0LoadNames tm a = Pass0LoadNames { runPass0LoadNames :: T tm a }
    deriving (Functor, Applicative, Monad)

instance Monad tm => MonadNaming (Pass0LoadNames tm) where
    type OldName (Pass0LoadNames tm) = UUID
    type NewName (Pass0LoadNames tm) = P0Out
    type TM (Pass0LoadNames tm) = tm
    opRun = pure runPass0LoadNames
    opWithParamName _ = p0cpsNameConvertor
    opWithLetName _ = p0cpsNameConvertor
    opWithTagName = p0cpsNameConvertor
    opGetName _ = p0nameConvertor

getP0Out :: Monad tm => UUID -> Pass0LoadNames tm P0Out
getP0Out uuid =
    Pass0LoadNames $ do
        nameStr <- Transaction.getP $ assocNameRef uuid
        pure P0Out
            { _mStoredName = if Text.null nameStr then Nothing else Just nameStr
            , _mStoredUUID = uuid
            }

p0nameConvertor :: Monad tm => Walk.NameConvertor (Pass0LoadNames tm)
p0nameConvertor = getP0Out

p0cpsNameConvertor :: Monad tm => Walk.CPSNameConvertor (Pass0LoadNames tm)
p0cpsNameConvertor uuid =
    CPS $ \k -> (,) <$> getP0Out uuid <*> k

------------------------------
---------- Pass 1 ------------
------------------------------

-- | Info about a single instance of use of a name:
data NameInstance = NameInstance
    { _niUUID :: !UUID
    , -- | Is the name used in a function application context? We consider
      -- the application as a disambiguator
      _niMApplied :: !(Maybe Walk.FunctionSignature)
    , _niNameType :: !Walk.NameType
    } deriving (Eq, Ord, Show)
Lens.makeLenses ''NameInstance

-- Wrap the Map for a more sensible (recursive) Monoid instance
newtype NameUUIDMap = NameUUIDMap (Map Text (OrderedSet NameInstance))
    deriving Show

type instance Lens.Index NameUUIDMap = Text
type instance Lens.IxValue NameUUIDMap = OrderedSet NameInstance

instance Lens.Ixed NameUUIDMap where
    ix k f (NameUUIDMap m) = NameUUIDMap <$> Lens.ix k f m
    {-# INLINE ix #-}
instance Lens.At NameUUIDMap where
    at k f (NameUUIDMap m) = NameUUIDMap <$> Lens.at k f m
    {-# INLINE at #-}

instance Monoid NameUUIDMap where
    mempty = NameUUIDMap Map.empty
    NameUUIDMap x `mappend` NameUUIDMap y =
        NameUUIDMap $ Map.unionWith mappend x y

nameUUIDMapSingleton :: Text -> NameInstance -> NameUUIDMap
nameUUIDMapSingleton name nameInstance =
    OrderedSet.singleton nameInstance & Map.singleton name & NameUUIDMap

data NamesWithin = NamesWithin
    { _snwUUIDMap :: NameUUIDMap
    -- Names of tags and defs: considered conflicted if used in two
    -- different meanings anywhere in the whole definition:
    , _snwGlobalNames :: NameUUIDMap
    } deriving (Generic)
Lens.makeLenses ''NamesWithin
instance Monoid NamesWithin where
    mempty = def_mempty
    mappend = def_mappend

data MName = Unnamed | Named Text
    deriving (Show, Eq, Ord)
toText :: MName -> Text
toText Unnamed = "Unnamed"
toText (Named name) = name

data P1Out = P1Out
    { p1Name :: Maybe MName
    , p1StoredUUID :: UUID
    , p1NamesWithin :: NamesWithin
    }
newtype Pass1PropagateUp (tm :: * -> *) a = Pass1PropagateUp (Writer NamesWithin a)
    deriving (Functor, Applicative, Monad)
p1TellNames :: NamesWithin -> Pass1PropagateUp tm ()
p1TellNames = Pass1PropagateUp . Writer.tell
p1ListenNames :: Pass1PropagateUp tm a -> Pass1PropagateUp tm (a, NamesWithin)
p1ListenNames (Pass1PropagateUp act) = Pass1PropagateUp $ Writer.listen act
runPass1PropagateUp :: Pass1PropagateUp tm a -> (a, NamesWithin)
runPass1PropagateUp (Pass1PropagateUp act) = runWriter act

data NameScope = Local | Global

nameTypeScope :: Walk.NameType -> NameScope
nameTypeScope Walk.ParamName = Local
nameTypeScope Walk.TagName = Global
nameTypeScope Walk.NominalName = Global
nameTypeScope Walk.DefName = Global

instance Monad tm => MonadNaming (Pass1PropagateUp tm) where
    type OldName (Pass1PropagateUp tm) = P0Out
    type NewName (Pass1PropagateUp tm) = P1Out
    type TM (Pass1PropagateUp tm) = tm
    opRun = pure (return . fst . runPass1PropagateUp)
    opWithParamName _ = p1cpsNameConvertor Walk.ParamName
    opWithLetName _ = p1cpsNameConvertor Walk.ParamName
    opWithTagName = p1cpsNameConvertor Walk.TagName
    opGetName = p1nameConvertor Nothing
    opGetAppliedFuncName = p1nameConvertor . Just

pass1Result ::
    Maybe Walk.FunctionSignature -> Walk.NameType -> P0Out ->
    Pass1PropagateUp tm (NamesWithin -> P1Out)
pass1Result mApplied nameType (P0Out mName uuid) =
    do
        p1TellNames myNamesWithin
        pure $ \namesUnder -> P1Out
            { p1Name = givenName
            , p1StoredUUID = uuid
            , p1NamesWithin = myNamesWithin `mappend` namesUnder
            }
    where
        singleton nameText =
            nameUUIDMapSingleton nameText
            NameInstance
            { _niUUID = uuid
            , _niMApplied = mApplied
            , _niNameType = nameType
            } & buildNamesWithin
        givenName =
            case (mName, nameType) of
            (Just name, _) -> Just (Named name)
            (Nothing, Walk.TagName) -> Just Unnamed
            (Nothing, Walk.DefName) -> Just Unnamed
            (Nothing, Walk.NominalName) -> Just Unnamed
            (Nothing, Walk.ParamName) -> Nothing
        myNamesWithin = maybe mempty (singleton . toText) givenName
        buildNamesWithin myNameUUIDMap =
            globalNames myNameUUIDMap
            & NamesWithin myNameUUIDMap
        globalNames myNameUUIDMap =
            case nameTypeScope nameType of
            Local -> mempty
            Global -> myNameUUIDMap

p1nameConvertor :: Maybe Walk.FunctionSignature -> Walk.NameType -> Walk.NameConvertor (Pass1PropagateUp tm)
p1nameConvertor mApplied nameType mStoredName =
    pass1Result mApplied nameType mStoredName
    <&> ($ mempty)

p1cpsNameConvertor :: Walk.NameType -> Walk.CPSNameConvertor (Pass1PropagateUp tm)
p1cpsNameConvertor nameType mNameSrc =
    CPS $ \k -> do
        result <- pass1Result Nothing nameType mNameSrc
        (res, namesWithin) <- p1ListenNames k
        pure (result namesWithin, res)

------------------------------
---------- Pass 2 ------------
------------------------------

data P2Env = P2Env
    { _p2NameGen :: NameGen UUID
    , _p2NameSuffixes :: Map UUID Int
    , _p2Names :: Set Text
    }
Lens.makeLenses ''P2Env

-- | Textual Name ambiguity
--
-- In the visible grammar, there are different types of names (see
-- Walk.NameType):
-- DefName, TagName, NominalName, ParamName
--
-- Each type can collide with itself. Nominals can only collide with
-- themselves (due to their grammatic context being unique).
--
-- Definitions and tags cannot collide with each other but both
-- can collide with param names.
--
-- Hence, we check collisions in three groups:
-- * Nominals
-- * Tags+Params
-- * Defs+Params
--
-- Defs+Params can also be disambiguated if used exclusively in
-- labeled apply contexts, and with differing signatures.

uuidSuffixes :: OrderedSet NameInstance -> Map UUID Int
uuidSuffixes nameInstances
    | namesClash (getNames Walk.NominalName)
    || namesClash (getNames Walk.TagName ++ getNames Walk.ParamName)
    || namesClash (getNames Walk.DefName ++ getNames Walk.ParamName)
    = zip uuids [0..] & Map.fromList
    | otherwise = mempty
    where
        getNames nameType = byType ^. Lens.ix nameType
        byType =
            nameInstances ^.. Lens.folded & MapUtils.partition (^. niNameType)
        uuids = (nameInstances ^. Lens.folded . niUUID . Lens.to OrderedSet.singleton) ^.. Lens.folded

-- | Given a list of UUIDs that are being referred to via the same
-- textual name, generate a suffix map
namesClash :: [NameInstance] -> Bool
namesClash nameInstances =
    Set.size uuids >= 2
    &&
    ( ListUtils.isLengthAtLeast 2 nameRefs
      || hasBothTypes
      || hasSameCallType
    )
    where
        uuids = nameInstances ^.. Lens.folded . niUUID & Set.fromList
        nameRefs = nameInstances ^.. Lens.folded . niMApplied . Lens._Nothing
        nameApps = nameInstances ^.. Lens.folded . niMApplied . Lens._Just
        -- | Same textual name used both as an application and as a
        -- normal name:
        hasBothTypes = not (null nameRefs) && not (null nameApps)
        -- | Multiple applications have same signature for differing
        -- UUIDs, still ambiguous:
        hasSameCallType = uniqueCount nameApps < length nameApps
        uniqueCount = Set.size . Set.fromList

emptyP2Env :: NameUUIDMap -> P2Env
emptyP2Env (NameUUIDMap globalNamesMap) =
    P2Env
    { _p2NameGen = NameGen.initial
    , _p2Names = mempty
    , _p2NameSuffixes = globalNamesMap ^.. traverse <&> uuidSuffixes & mconcat
    }

newtype Pass2MakeNames (tm :: * -> *) a = Pass2MakeNames (Reader P2Env a)
    deriving (Functor, Applicative, Monad)
runPass2MakeNames :: P2Env -> Pass2MakeNames tm a -> a
runPass2MakeNames initial (Pass2MakeNames act) = runReader act initial
p2GetEnv :: Pass2MakeNames tm P2Env
p2GetEnv = Pass2MakeNames Reader.ask
p2WithEnv :: (P2Env -> P2Env) -> Pass2MakeNames tm a -> Pass2MakeNames tm a
p2WithEnv f (Pass2MakeNames act) = Pass2MakeNames $ Reader.local f act

runPass2MakeNamesInitial :: NamesWithin -> Pass2MakeNames tm a -> a
runPass2MakeNamesInitial namesWithin = runPass2MakeNames (emptyP2Env (namesWithin ^. snwGlobalNames))

setName :: Monad tm => UUID -> StoredName -> T tm ()
setName = Transaction.setP . assocNameRef

instance Monad tm => MonadNaming (Pass2MakeNames tm) where
    type OldName (Pass2MakeNames tm) = P1Out
    type NewName (Pass2MakeNames tm) = Name tm
    type TM (Pass2MakeNames tm) = tm
    opRun = p2GetEnv <&> runPass2MakeNames <&> (return .)
    opWithTagName = p2cpsNameConvertorGlobal
    opWithParamName = p2cpsNameConvertorLocal
    opWithLetName = p2cpsNameConvertorLocal
    opGetName Walk.ParamName (P1Out mName uuid namesUnder) =
        case mName of
            Just name ->
                makeFinalName name namesUnder uuid <$> p2GetEnv
            Nothing ->
                do
                    nameGen <- (^. p2NameGen) <$> p2GetEnv
                    let name = evalState (NameGen.existingName uuid) nameGen
                    pure $
                        Name SourceAutoGenerated NoCollision (setName uuid) name
    opGetName Walk.TagName x = p2nameConvertorGlobal x
    opGetName Walk.NominalName x = p2nameConvertorGlobal x
    opGetName Walk.DefName x = p2nameConvertorGlobal x

makeFinalName ::
    Monad tm => MName -> NamesWithin -> UUID -> P2Env -> Name tm
makeFinalName name namesWithin uuid env =
    fst $ makeFinalNameEnv name namesWithin uuid env

compose :: [a -> a] -> a -> a
compose = foldr (.) id

makeFinalNameEnv ::
    Monad tm =>
    MName -> NamesWithin -> UUID -> P2Env -> (Name tm, P2Env)
makeFinalNameEnv name namesWithin uuid env =
    (Name nameSrc collision (setName uuid) (toText name), newEnv)
    where
        nameSrc =
            case name of
            Unnamed -> SourceAutoGenerated
            Named _ -> SourceStored
        (collision, newEnv) =
            case (mSuffixFromAbove, collidingUUIDs) of
                (Just suffix, _) -> (Collision suffix, env)
                (Nothing, []) -> (NoCollision, envWithName [])
                (Nothing, otherUUIDs) -> (Collision 0, envWithName (uuid:otherUUIDs))
        nameText = toText name
        envWithName uuids = env
            & p2Names %~ Set.insert nameText
            -- This name is first occurence, so we get suffix 0
            & p2NameSuffixes %~ compose ((Lens.itraversed %@~ flip Map.insert) uuids)
        mSuffixFromAbove =
            Map.lookup uuid $ env ^. p2NameSuffixes
        collidingUUIDs =
            namesWithin
            ^. snwUUIDMap . Lens.at nameText . Lens._Just .
                Lens.folded . niUUID . Lens.filtered (/= uuid) . Lens.to OrderedSet.singleton
            ^.. Lens.folded

p2cpsNameConvertor ::
    Monad tm =>
    P1Out ->
    (P2Env -> (Name tm, P2Env)) ->
    CPS (Pass2MakeNames tm) (Name tm)
p2cpsNameConvertor (P1Out mName uuid namesWithin) nameMaker =
    CPS $ \k ->
    do
        oldEnv <- p2GetEnv
        let (newName, newEnv) =
                case mName of
                Just name -> makeFinalNameEnv name namesWithin uuid oldEnv
                Nothing -> nameMaker oldEnv
        res <- p2WithEnv (const newEnv) k
        return (newName, res)

p2cpsNameConvertorGlobal :: Monad tm => Walk.CPSNameConvertor (Pass2MakeNames tm)
p2cpsNameConvertorGlobal p1out =
    makeFinalNameEnv Unnamed (p1NamesWithin p1out) (p1StoredUUID p1out)
    & p2cpsNameConvertor p1out

p2cpsNameConvertorLocal :: Monad tm => NameGen.VarInfo -> Walk.CPSNameConvertor (Pass2MakeNames tm)
p2cpsNameConvertorLocal isFunction p1out =
    p2cpsNameConvertor p1out $ \p2env ->
    (`runState` p2env) . Lens.zoom p2NameGen $
        let conflict name =
                Lens.has (snwUUIDMap . Lens.at name . Lens._Just) namesWithin ||
                (p2env ^. p2Names . Lens.contains name)
        in
            Name SourceAutoGenerated NoCollision (setName uuid) <$>
            NameGen.newName (not . conflict) isFunction uuid
    where
        P1Out _ uuid namesWithin = p1out

p2nameConvertorGlobal :: Monad tm => Walk.NameConvertor (Pass2MakeNames tm)
p2nameConvertorGlobal (P1Out mName uuid namesWithin) =
    p2GetEnv <&> makeFinalName name namesWithin uuid
    where
        -- We use "Nothing" to signify auto-gen needed as output from
        -- phase1, and we only do so for local names, whereas this is
        -- a global name:
        name = fromMaybe (Named "TODO: Bug") mName

fixVarToTags :: Monad m => VarToTags -> T m ()
fixVarToTags VarToTags {..} =
    Transaction.getP (assocNameRef vttReplacedVar)
    >>= Transaction.setP (assocNameRef (vttReplacedByTag ^. tagVal))

fixParamAddResult :: Monad m => ParamAddResult -> T m ()
fixParamAddResult (ParamAddResultVarToTags v) = fixVarToTags v
fixParamAddResult _ = return ()

fixParamDelResult :: Monad m => ParamDelResult -> T m ()
fixParamDelResult (ParamDelResultTagsToVar TagsToVar {..}) =
    Transaction.getP (assocNameRef (ttvReplacedTag ^. tagVal))
    >>= Transaction.setP (assocNameRef ttvReplacedByVar)
fixParamDelResult _ = return ()

fixLetFloatResult :: Monad m => LetFloatResult -> T m ()
fixLetFloatResult = traverse_ fixVarToTags . lfrMVarToTags

-- mutual recursion fixBinder<->fixExpr

fixBinder ::
    Monad m =>
    Binder name m (Expression name m a) ->
    Binder name m (Expression name m a)
fixBinder binder =
    binder
    & SugarLens.binderFuncParamAdds %~ postProcess fixParamAddResult
    & SugarLens.binderFuncParamDeletes %~ postProcess fixParamDelResult
    & bBody . bbContent %~ fixBinderContent
    where
        fixBinderContent x =
            x
            & _BinderExpr %~ fixExpr
            & _BinderLet . lValue %~ fixBinder
            & _BinderLet . lBody . bbContent %~ fixBinderContent
            & _BinderLet . lActions . laFloat %~ postProcess fixLetFloatResult
        postProcess f action =
            do
                res <- action
                () <- f res
                return res

fixExpr :: Monad m => Expression name m a -> Expression name m a
fixExpr expr =
    expr & rBody %~ \case
    BodyLam lam -> lam & lamBinder %~ fixBinder & BodyLam
    body -> body <&> fixExpr

runPasses ::
    Functor tm =>
    (a -> Pass0LoadNames tm b) -> (b -> Pass1PropagateUp tm c) -> (c -> Pass2MakeNames tm d) ->
    a -> T tm d
runPasses f0 f1 f2 =
    fmap (pass2 . pass1) . pass0
    where
        pass0 = runPass0LoadNames . f0
        pass1 = runPass1PropagateUp . f1
        pass2 (x, namesWithin) =
            f2 x & runPass2MakeNamesInitial namesWithin

fixDef ::
    Monad tm =>
    Definition name tm (Expression name tm a) ->
    Definition name tm (Expression name tm a)
fixDef = drBody . _DefinitionBodyExpression . deContent %~ fixBinder

addToWorkArea :: Monad tm => WorkArea UUID tm a -> T tm (WorkArea (Name tm) tm a)
addToWorkArea workArea =
    workArea
    & waPanes . traverse . paneDefinition %~ fixDef
    & waRepl %~ fixExpr
    & runPasses f f f
    where
        f = Walk.toWorkArea
