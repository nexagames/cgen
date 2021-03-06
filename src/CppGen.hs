module CppGen(handleHeader)
where

import System.FilePath
import System.IO
import Data.List
import Data.Maybe
import Control.Monad
import Text.Printf
import qualified Data.Set as S

import Text.Regex.Posix
import Safe

import HeaderData
import CppUtils
import Utils

publicMemberFunction :: Object -> Bool
publicMemberFunction (FunDecl _ _ _ _ (Just (Public, _)) _ _) = True
publicMemberFunction _                                      = False

showP (ParamDecl pn pt _ _) = pt ++ " " ++ pn

paramFormat :: [ParamDecl] -> String
paramFormat (p1:p2:ps) = showP p1 ++ ", " ++ paramFormat (p2:ps)
paramFormat [p1]       = showP p1
paramFormat []         = ""

correctParam :: ParamDecl -> ParamDecl
correctParam p = p{vartype = correctType (vartype p)} -- TODO: arrays?

refToPointerParam :: ParamDecl -> ParamDecl
refToPointerParam p = p{vartype = refToPointer (vartype p)}

refToPointer :: String -> String
refToPointer t = 
  if last t == '&'
    then init t ++ "*"
    else t

handleHeader :: FilePath -> [FilePath] -> [String] -> [String] -> [(String, String)] -> FilePath -> [Object] -> IO ()
handleHeader outdir incfiles exclclasses excls rens headername objs = do
    withFile outfile WriteMode $ \h -> do
        hPrintf h "#ifndef CGEN_%s_H\n" (toCapital (takeBaseName headername))
        hPrintf h "#define CGEN_%s_H\n" (toCapital (takeBaseName headername))
        hPrintf h "\n"
        forM_ incfiles $ \inc -> do
            hPrintf h "#include <%s>\n" inc
        hPrintf h "\n"
        hPrintf h "extern \"C\"\n"
        hPrintf h "{\n"
        hPrintf h "\n"
        forM_ namespaces $ \ns -> do
            hPrintf h "using namespace %s;\n" ns
        hPrintf h "\n"
        forM_ typedefs $ \(td1, td2) -> do
            hPrintf h "typedef %s %s;\n" td1 td2
        hPrintf h "\n\n"
        hPrintf h "#ifdef CGEN_HS\n"
        forM_ (getEnums objs) $ \enum -> do
            hPutStrLn h $ enumDeclaration (enumname enum) (enumvalues enum)
        hPrintf h "#endif\n\n"

        forM_ funs $ \fun -> do
            hPutStrLn h $ funDeclaration (funname fun) (rettype fun) (paramFormat (params fun))
        hPrintf h "\n"
        hPrintf h "}\n"
        hPrintf h "\n"
        hPrintf h "#endif\n"
        hPrintf h "\n"
        hPutStrLn stderr $ "Wrote file " ++ outfile

    withFile cppoutfile WriteMode $ \h -> do
        hPrintf h "#define CGEN_OUTPUT_INTERN\n"
        hPrintf h "#include \"%s\"" headername
        hPrintf h "\n"
        forM_ (zip funs allfuns) $ \(fun, origfun) -> do
            hPrintf h "%s %s(%s)\n" 
                (stripStatic $ rettype fun)
                (funname fun)
                (paramFormat (params fun))
            hPrintf h "{\n"
            -- NOTE: do NOT call refToPointerParam or refParamsToPointers
            -- for prs, because then the information that the parameter
            -- is actually a reference and the pointer must be dereferenced
            -- is lost.
            let prs = intercalate ", " $ map (correctRef . renameParam rens) $ params $ correctFuncParams origfun
            switch (funname origfun)
              [(getClname origfun,      hPrintf h "    return new %s(%s);\n" (stripStatic $ stripExtra $ rettype fun) prs),
               ('~':getClname origfun,  hPrintf h "    delete this_ptr;\n")]
              (hPutStrLn h $ funDefinition (funname origfun) (rettype fun) (getClname origfun) prs)
            hPrintf h "}\n"
            hPrintf h "\n"
        hPutStrLn stderr $ "Wrote file " ++ cppoutfile

  where outfile    = (outdir </> headername)
        cppoutfile = (outdir </> takeBaseName headername <.> "cpp")
        allfuns    = implicitcdtors ++ filter (\f -> publicMemberFunction f && 
                                   not (excludeFun f) && 
                                   not (abstractConstructor classes f)) (getFuns objs)
        implicitcdtors = concatMap getImplicitCDtor classes
        namespaces = filter (not . null) $ nub $ map (headDef "") (map fnnamespace funs)
        -- list of names of all parsed classes
        classnames = filter (not . null) $ nub $ map getObjName $ getClasses objs
        classes    = concatMap (\nm -> filter (classHasName nm) (getClasses objs)) classnames
        alltypedefs = catMaybes $ map getTypedef (map snd $ concatMap classobjects classes)
        -- typedefs used in function parameter and return types
        usedtypedefs = usedTypedefs usedtypes alltypedefs
        extratypedefs = extraTypedefs usedtypedefs alltypedefs
        -- NOTE: can't just use only public typedefs, because they sometimes depend on 
        -- protected typedefs, so include them as well (so-called secondary typedefs).
        typedefs   = nub $ extratypedefs ++ usedtypedefs
        allenums   = map snd $ filter (\(v, o) -> isEnum o && v == Public) $ concatMap classobjects classes
        funs       = mangle $ map expandFun allfuns
        excludeFun f = lastDef ' ' (correctType $ rettype f) == '&' || -- TODO: allow returned references
                       or (map (\e -> funname f =~ e) excls) ||
                       or (map (\e -> fromMaybe "" (liftM snd (fnvisibility f)) =~ e) exclclasses) ||
                       take 8 (rettype f) == "template" ||  -- TODO: allow return types that start with "template"
                       rettype f == "operator" ||  -- conversion operator is parsed as operator as return type
                       take 8 (funname f) == "operator"  -- TODO: allow normal functions with name starting with operator
        expandFun f = addConstness . -- add const keyword if the function is const
                      refParamsToPointers . -- ref params to pointers
                      renameTypes rens . -- rename types as specified by user
                      addClassspaces allenums classes . -- add qualification when necessary
                      correctFuncRetType . -- remove keywords from return type
                      correctFuncParams . -- create param name if none, remove keywords
                      finalName . -- expand function name by class and namespace
                      addThisPointer .  -- 1st parameter
                      extendFunc $ f -- constructor & destructor handling
        usedtypes  = getAllTypes funs

getImplicitCDtor :: Object -> [Object]
getImplicitCDtor c@(ClassDecl cname _ _ cns objs)
  | null $ filter (not . isAbstractFun) $ getFuns . map snd . filter (\(p, _) -> p == Public) $ objs
      = [] -- forward declaration or abstract
  | not (publicClass c)
      = [] 
  | abstractClass c
      = [] 
  | otherwise
      = dl ++ cl
      where dl = if any isDestructor (map snd objs) -- explicit destructor
                   then []
                   else [FunDecl ('~':cname) "void" [] cns (Just (Public, cname)) False False]
            cl = if any isConstructor (map snd objs) -- explicit constructor
                   then []
                   else [FunDecl cname "" [] cns (Just (Public, cname)) False False]
getImplicitCDtor _ = []

isConstructor :: Object -> Bool
isConstructor (FunDecl fname _ _ _ (Just (_, cname)) _ _) = fname == cname
isConstructor _                                           = False

isDestructor :: Object -> Bool
isDestructor (FunDecl fname _ _ _ (Just (_, cname)) _ _) = fname == '~':cname
isDestructor _                                           = False

funDefinition :: String -> String -> String -> String -> String
funDefinition fnname rttype clname fnparams
  | rttype == "void" 
      = printf "    this_ptr->%s(%s);" fnname fnparams
  | isStatic rttype && stripStatic rttype == "void" 
      = printf "    %s::%s(%s);" clname fnname fnparams
  | isStatic rttype 
      = printf "    return %s::%s(%s);" clname fnname fnparams
  | otherwise 
      = printf "    return this_ptr->%s(%s);" fnname fnparams

funDeclaration :: String -> String -> String -> String
funDeclaration fnname rttype fnparams =
    printf "%s %s(%s);" (stripStatic rttype) fnname fnparams

enumDeclaration :: String -> [EnumVal] -> String
enumDeclaration ename evalues = 
  if not (enumReadable evalues) then "" else printf "enum %s {\n    %s\n};\n\n" ename vals
    where vals = intercalate ",\n    " (map printEnumval (getEnumValues evalues))

printEnumval :: (String, Int) -> String 
printEnumval (n, v) = printf "%s = %d" n v

refParamsToPointers f@(FunDecl _ _ ps _ _ _ _) =
  f{params = map refToPointerParam ps}
refParamsToPointers n = n

renameTypes :: [(String, String)] -> Object -> Object
renameTypes rens f@(FunDecl _ rt ps _ _ _ _) =
    f{rettype = renameType rens rt,
      params = map (renameParam rens) ps}
renameTypes _ n = n

renameParam :: [(String, String)] -> ParamDecl -> ParamDecl
renameParam rens p@(ParamDecl _ pt _ _) =
    p{vartype = renameType rens pt}

renameType :: [(String, String)] -> String -> String
renameType rens t =
  let mnt = lookup tm rens
      tm = stripStatic $ stripExtra t
      mf1 = if isConst t then makeConst else id
      mf2 = makePtr (isPtr t)
  in case mnt of
       Nothing -> if '<' `elem` t && '>' `elem` t
                    then handleTemplateTypes rens t
                    else t
       Just t' -> if isStatic (stripExtra t)
                    then "static " ++ ((mf1 . mf2) t')
                    else (mf1 . mf2) t'

handleTemplateTypes :: [(String, String)] -> String -> String
handleTemplateTypes rens t = 
  let alltypes = typesInType t
      newtypes = map (renameType rens) alltypes
  in foldr (uncurry replace) t (zip alltypes newtypes)

makeConst :: String -> String
makeConst n = "const " ++ n

makePtr :: Int -> String -> String
makePtr num t = t ++ replicate num '*'

abstractConstructor :: [Object] -> Object -> Bool
abstractConstructor classes (FunDecl fn _ _ _ (Just (_, _)) _ _) =
  case fetchClass classes fn of
    Nothing -> False
    Just cl -> any isAbstractFun (map snd $ classobjects cl)
abstractConstructor _       _                                  = False

-- typesInType "const int" = ["int"]
-- typesInType "map<String, Animation*>::type" = ["String", "Animation"]
typesInType :: String -> [String]
typesInType v =
    case betweenAngBrackets v of
      "" -> [stripExtra v]
      n  -> map stripExtra $ splitBy ',' n

-- all typedefs whose definition depends on another typedef.
extraTypedefs :: [(String, String)] -> [(String, String)] -> [(String, String)]
extraTypedefs usedts allts = 
  case filter (extractSecType usedts) allts of
    []        -> []
                 -- NOTE: the order here is significant for the dependencies
                 -- between the typedefs.
    newusedts -> extraTypedefs newusedts allts ++ newusedts

-- whether any of the types in the snd of the tuple is contained in
-- any of the fsts of the list.
extractSecType :: [(String, String)] -> (String, String) -> Bool
extractSecType ts (_, t2) = 
  let sectypes = typesInType t2
      tsstypes = concatMap typesInType (map fst ts)
  in (any (`elem` tsstypes) sectypes)

-- for all types of a function, turn "y" into "x::y" when y is a nested class inside x.
addClassspaces :: [Object] -> [Object] -> Object -> Object
addClassspaces enums classes f@(FunDecl _ rt ps _ _ _ _) =
  let rt' = addClassQual enums classes rt
      ps' = map (addParamClassQual enums classes) ps
  in f{rettype = rt',
       params  = ps'}
addClassspaces _     _       n                         = n

addParamClassQual :: [Object] -> [Object] -> ParamDecl -> ParamDecl
addParamClassQual enums classes p@(ParamDecl _ t _ _) =
  let t' = addClassQual enums classes t
  in p{vartype = t'}

-- add class qualification to rt, if a class named rt is found.
-- the qualification added is the class nesting of the found class.
addClassQual :: [Object] -> [Object] -> String -> String
addClassQual enums classes rt =
  case fetchClass classes (stripStatic $ stripExtra rt) of
    Nothing -> case fetchEnum enums (stripStatic $ stripExtra rt) of
                 Nothing -> rt
                 Just e  -> addNamespaceQual (map snd $ enumclassnesting e) rt
    Just c  -> addNamespaceQual (map snd $ classnesting c) rt

-- addNamespaceQual ["aa", "bb"] "foo" = "bb::aa::foo"
-- addNamespaceQual ["aa", "bb"] "static foo" = "static bb::aa::foo"
addNamespaceQual :: [String] -> String -> String
addNamespaceQual ns n
  | isStatic n = "static " ++ addNamespaceQual ns (stripStatic n)
  | otherwise  = concatMap (++ "::") ns ++ n

-- turn a "char& param" into "*param".
correctRef :: ParamDecl -> String
correctRef (ParamDecl nm pt _ _) =
  if '&' `elem` take 2 (reverse pt)
    then '*':nm
    else nm

-- separate pointer * from other chars for all params.
-- if param has no name, create one.
-- remove keywords such as virtual, etc.
correctFuncParams :: Object -> Object
correctFuncParams f@(FunDecl _ _ ps _ _ _ _) = 
  f{params = checkParamNames (map (correctParam) ps)}
correctFuncParams n                                 = n

-- for each unnamed parameter,
-- create a parameter name of (type) ++ running index.
checkParamNames :: [ParamDecl] -> [ParamDecl]
checkParamNames = go (1 :: Int)
  where go _ []     = []
        go n (p:ps) =
          let (p', n') = case varname p of
                           "" -> (p{varname = (stripStatic $ stripExtra $ vartype p) ++ (show n)}, n + 1)
                           _  -> (p, n)
          in p':(go n' ps)

-- expand function name by namespace and class name.
finalName :: Object -> Object
finalName f@(FunDecl fname _ _ funns _ _ _) =
  let clname = getClname f
      nsname = headDef "" funns
      updname = nsname ++ (if not (null nsname) then "_" else "") ++ 
                clname ++ (if not (null clname) then "_" else "") ++ fname
  in f{funname = updname}
finalName n = n

constructorName, destructorName :: String
constructorName = "new"
destructorName = "delete"

addThisPointer :: Object -> Object
addThisPointer f@(FunDecl fname rttype ps _ (Just (_, clname)) _ _)
  | fname == constructorName = f
  | isStatic rttype          = f
  | otherwise
    = f{params = (t:ps)}
      where t = ParamDecl this_ptrName (clname ++ "*") Nothing Nothing
addThisPointer n = n

this_ptrName = "this_ptr"

-- correct constructors and destructors.
extendFunc :: Object -> Object
extendFunc f@(FunDecl fname _ _ _ (Just (_, clname)) _ _) 
  | fname == clname = f{funname = constructorName,
                        rettype = fname ++ " *"}
  | fname == '~':clname = f{funname = destructorName,
                            rettype = "void"}
  | otherwise           = f
extendFunc n = n

-- const keyword to return value and this_ptr if needed.
addConstness :: Object -> Object
addConstness f@(FunDecl _ fr ps _ _ constfunc _)
  = f{rettype = cident fr,
      params = map cidentP ps}
      where cident  v = if not (isConst v) && 
                           constfunc && 
                           '*' `elem` v 
                          then "const " ++ v 
                          else v
            cidentP p = let n = if not (isConst (varname p)) &&
                                   constfunc && 
                                   varname p == this_ptrName
                                  then "const " ++ vartype p
                                  else vartype p
                        in p{vartype = n}
addConstness n = n

-- filtering typedefs doesn't help - t1 may refer to private definitions.
usedTypedefs :: S.Set String -> [(String, String)] -> [(String, String)]
usedTypedefs s = filter (\(_, t2) -> t2 `S.member` s)

-- separate pointer * from other chars in function return type.
-- remove keywords such as virtual, etc.
correctFuncRetType :: Object -> Object
correctFuncRetType f@(FunDecl _ fr _ _ _ _ _)
  = f{rettype = correctType fr}
correctFuncRetType n = n

-- o(n^2).
-- adds cleaned up type names at the end of the overloaded function name.
mangle :: [Object] -> [Object]
mangle []     = []
mangle (n:ns) = 
  let m   = n{funname = funname n ++ functionMangleSuffix n}
  in if null $ filter (== funname n) $ map funname ns
       then n : mangle ns
       else m : mangle ns

functionMangleSuffix :: Object -> String
functionMangleSuffix (FunDecl _ _ [] _ _ _ _) = "_void"
functionMangleSuffix (FunDecl _ _ ps _ _ _ _) = '_' : concatMap (mangleType . vartype) ps
functionMangleSuffix _ = ""

mangleType :: String -> String
mangleType = filter (`notElem` ": <>") . map (\c -> if c == '*' then 'P' else if c == '&' then 'R' else c) . replace "::type" "" . stripConst
