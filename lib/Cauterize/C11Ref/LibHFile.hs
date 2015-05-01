{-# LANGUAGE QuasiQuotes #-}
module Cauterize.C11Ref.LibHFile
  ( hFileFromSpec
  ) where

import Cauterize.C11Ref.Util

import Data.Char (toUpper)
import Data.List (intercalate)
import Data.Maybe
import Data.String.Interpolate
import Data.String.Interpolate.Util
import Data.Text.Lazy (unpack)
import Numeric
import qualified Cauterize.Common.Types as S
import qualified Cauterize.Specification as S
import qualified Data.Map as M

hFileFromSpec :: S.Spec -> String
hFileFromSpec = unindent . concat . fromSpec

fromSpec :: S.Spec -> [String]
fromSpec s = [chompNewline [i|
  #ifndef #{guardSym}
  #define #{guardSym}

  #include "cauterize.h"
|]
  , comment "library meta information"
  , chompNewline [i|
  #define NAME_#{ln} "#{ln}"
  #define VERSION_#{ln} "#{unpack $ S.specVersion s}"
  #define MIN_SIZE_#{ln} (#{S.minSize libsize})
  #define MAX_SIZE_#{ln} (#{S.maxSize libsize})
  #define NUM_TYPES_#{ln} (#{length types})
|]
  , comment "schema hash"
  , [i|  extern hashtype_t const SCHEMA_HASH_#{ln};|]
  , blankLine

  , comment "type indicies"
  , chompNewline [i|
  enum type_index_#{ln} {
#{typeIndicies}
  };
|]

  , comment "forward declarations"
  , unlines (mapMaybe typeForwardDecl types)

  , comment "type definitions"
  , unlines (mapMaybe (typeDefinition luDecl) types)

  , [i|
  /* message interface */
  #define TYPE_TAG_WIDTH_#{ln} (#{(S.unTypeTagWidth . S.specTypeTagWidth) s})
  #define LENGTH_WIDTH_#{ln} (#{(S.unLengthTagWidth . S.specLengthTagWidth) s})

  #define MESSAGE_OVERHEAD_#{ln} (TYPE_TAG_WIDTH_#{ln} + LENGTH_WIDTH_#{ln})
  #define MESSAGE_MAX_SIZE_#{ln} (MESSAGE_OVERHEAD_#{ln} + MAX_SIZE_#{ln})
  #define MESSAGE_MIN_SIZE_#{ln} (MESSAGE_OVERHEAD_#{ln} + MIN_SIZE_#{ln})

  /* type descriptors extern */
  typedef struct caut_type_descriptor caut_type_descriptors_#{ln}_t[NUM_TYPES_#{ln}];
  extern const caut_type_descriptors_#{ln}_t type_descriptors;

  struct message_header_#{ln} {
    size_t length;
    uint8_t tag[TYPE_TAG_WIDTH_#{ln}];
  };

  struct message_#{ln} {
    enum type_index_#{ln} _type;
#{unionDecl}
  };

  enum caut_status encode_message_#{ln}(
    struct caut_encode_iter * const _iter,
    struct message_#{ln} const * const _obj);

  enum caut_status decode_message_header_#{ln}(
    struct caut_decode_iter * const _iter,
    struct message_header_#{ln} * const _header);

  enum caut_status decode_message_#{ln}(
    struct caut_decode_iter * const _iter,
    struct message_header_#{ln} const * const _header,
    struct message_#{ln} * const _obj);
|]

  , comment "function prototypes"
  , unlines (map typeFuncPrototypes types)

  , blankLine
  , chompNewline [i|
  #endif /* #{guardSym} */
|]
  ]
  where
    guardSym = [i|_CAUTERIZE_C11REF_#{ln}_|]
    blankLine = "\n"
    libsize = S.specSize s
    ln = unpack $ S.specName s
    types = S.specTypes s
    typeIndicies =
      let withIndex = zip [(0 :: Integer)..] types
      in intercalate "\n" $ map (\(ix,t) -> [i|    type_index_#{ln}_#{S.typeName t} = #{ix},|]) withIndex
    typeUnionFields = intercalate "\n" $ map (\t -> [i|      #{t2decl t} msg_#{S.typeName t};|]) types

    unionDecl =
      if length types <= 0
        then ""
        else [i|
    union {
#{typeUnionFields}
    } _data;
|]

    -- Names to how you delcare that name
    n2declMap = let s' = S.specTypes s
                    d = map t2decl s'
                    n = fmap S.typeName s'
                in M.fromList $ zip n d
    luDecl n = fromMaybe (error $ "Invalid name: " ++ unpack n ++ ".")
                         (M.lookup n n2declMap)

typeForwardDecl :: S.SpType -> Maybe String
typeForwardDecl t = fmap ("  " ++) (go t)
  where
    n = S.typeName t
    structish flavor = Just [i|struct #{n}; /* #{flavor} */|]
    go S.BuiltIn { S.unBuiltIn = S.TBuiltIn { S.unTBuiltIn = b } } =
      case b of
        S.BIbool -> Nothing -- We don't want to redefine 'bool'. stdbool.h defines this for us.
        b' -> Just [i|typedef #{bi2c b'} #{n}; /* builtin */|]
    go S.Synonym { S.unSynonym = S.TSynonym { S.synonymRepr = r } } =
      Just [i|typedef #{bi2c r} #{n}; /* synonym */|]
    go S.Array {} = structish "array"
    go S.Vector {} = structish "vector"
    go S.Record {} = structish "record"
    go S.Combination {} = structish "combination"
    go S.Union {} = structish "union"

typeFuncPrototypes :: S.SpType -> String
typeFuncPrototypes t = chompNewline [i|
  enum caut_status encode_#{n}(struct caut_encode_iter * const _c_iter, #{d} const * const _c_obj);
  enum caut_status decode_#{n}(struct caut_decode_iter * const _c_iter, #{d} * const _c_obj);
  size_t encoded_size_#{n}(#{d} const * const _c_obj);
  void init_#{n}(#{d} * _c_obj);
  enum caut_ord order_#{n}(#{d} const * const _c_a, #{d} const * const _c_b);
|]
  where
    d = t2decl t
    n = S.typeName t

typeDefinition :: (S.Name -> String) -> S.SpType -> Maybe String
typeDefinition refDecl t =
  case t of
    S.Array { S.unArray = S.TArray { S.arrayRef = r, S.arrayLen = l } } -> Just $ defArray n (refDecl r) l
    S.Vector { S.unVector = S.TVector { S.vectorRef = r, S.vectorMaxLen = l }
              , S.lenRepr = S.LengthRepr lr } -> Just $ defVector n (refDecl r) l lr
    S.Record { S.unRecord = S.TRecord { S.recordFields = S.Fields fs } } -> Just $ defRecord n refDecl fs
    S.Combination { S.unCombination = S.TCombination { S.combinationFields = S.Fields fs }
                  , S.flagsRepr = S.FlagsRepr fr } -> Just $ defCombination n refDecl fs fr
    S.Union { S.unUnion = S.TUnion { S.unionFields = S.Fields fs } } -> Just $ defUnion n refDecl fs
    _ -> Nothing
  where
    n = unpack $ S.typeName t

defArray :: String -> String -> Integer -> String
defArray n refDecl len =
  let lenSym = [i|ARRAY_LEN_#{n}|]
  in chompNewline [i|
  #define #{lenSym} (#{len})
  struct #{n} {
    #{refDecl} elems[#{lenSym}];
  };
|]

defVector :: String -> String -> Integer -> S.BuiltIn -> String
defVector n refDecl len lenRep =
  let maxLenSym = [i|VECTOR_MAX_LEN_#{n}|]
      lenRepDecl = bi2c lenRep
  in chompNewline [i|
  #define #{maxLenSym} (#{len})
  struct #{n} {
    #{lenRepDecl} _length;
    #{refDecl} elems[#{maxLenSym}];
  };
|]

defRecord :: String -> (S.Name -> String) -> [S.Field] -> String
defRecord n refDecl fields = chompNewline [i|
  struct #{n} {
    #{fdefs}
  };
|]
  where
    defField S.Field { S.fName = fn, S.fRef = fr} = [i|#{refDecl fr} #{fn};|]
    defField f@S.EmptyField {} = emptyFieldComment f
    fdefs = intercalate "\n    " $ map defField fields

defCombination :: String -> (S.Name -> String) -> [S.Field] -> S.BuiltIn -> String
defCombination n refDecl fields flagsRepr = chompNewline [i|
  #define COMBINATION_FLAGS_#{n} (0x#{flagsMask}ull)
  struct #{n} {
    #{bi2c flagsRepr} _flags;
    #{fdefs}
  };
|]
  where
    flagsMask = case length fields of
                  0 -> "0"
                  l -> map toUpper $ showHex (((2 :: Integer) ^ l) - 1) ""
    defField S.Field { S.fName = fn, S.fRef = fr} = [i|#{refDecl fr} #{fn};|]
    defField f@S.EmptyField {} = emptyFieldComment f
    fdefs = intercalate "\n    " $ map defField fields

defUnion :: String -> (S.Name -> String) -> [S.Field] -> String
defUnion n refDecl fields = chompNewline [i|
  #define UNION_NUM_FIELDS_#{n} (0x#{numFields}ull)
  struct #{n} {
    enum #{n}_tag {
      #{tagDefs}
    } _tag;

#{unionDecl}
  };
|]
  where
    defField S.Field { S.fName = fn, S.fRef = fr} = [i|#{refDecl fr} #{fn};|]
    defField f@S.EmptyField {} = emptyFieldComment f
    defTag f = [i|#{n}_tag_#{S.fName f} = #{S.fIndex f},|]
    fdefs = intercalate "\n      " $ map defField fields
    tagDefs = intercalate "\n      " $ map defTag fields
    numFields = length fields

    isEmpty S.EmptyField {} = True
    isEmpty _ = False

    unionDecl =
      if length (filter (not . isEmpty) fields) <= 0
        then ""
        else [i|
    union {
      #{fdefs}
    };
|]

emptyFieldComment :: S.Field -> String
emptyFieldComment S.EmptyField { S.fName = fn, S.fIndex = ix } = [i|/* no data for field #{fn} with index #{ix} */|]
emptyFieldComment _ = error "emptyFieldComment: invalid for all but EmptyField"
