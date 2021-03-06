# Implementation 

## Overview

The Pointer analysis is an Andersen style analysis

It has two steps:

1. the first step is using the frontend to generate relations or rules
2. the second step is using the Prolog engine for the pointer analysis

The first step is done by the compiler frontend `bin/ast2db`, it extracts information about the AST tree and exports the knowledge base in the form of triples `subject, relation, object`. The format is further transformed to ntriples(.trp) format in order to be loaded by the Prolog.

The second step is further divided into two parts. The first part deals with the syntax information since the input to the pointer analysis is some constrains extracted from the code. Besides, since different compilers like Clang or Rose may use different terms and organizations for the AST tree, the knowledge base should be preprocessed and aligned. This step is done by the `RelationGenClang.pl`.

The second part, `andersen.pl`, uses relations generated by last part and do the inference. This part should be generic and independent with compilers if the compiler generates compatible relations required by it.

The diagram is like this: 

```
       .c file
          +
          |
+---------+ --------+
|ast2db,cs|2ntriples|
+-------------------+
          |
          v
         (KB) knowledge about the AST tree
          +
          |
          v
       generate Relations/contrains
       relation
          +
          |
          v
   Inference Engine
          +
          |
          v
       Results
```

## The relation specification

```
%% ---------------- 
%% Input relations  
%% ---------------- 

%% BASIC ::=
%% p = alloc()
%% | p = &x
%% alloc(P, Loc).
%% address(Var, Loc).

%% COPY ::=
%% to = from
%% copy(ToVar, FromVar).

%% LOAD ::=
%% deref p = *q
%% | field read (to = base.fld)
%% | array read p = array[]
%% load(ToVar, DerefVar).
%% fieldLoad(ToVar, BaseVar, Fld).
%% arrayLoad(ToVar, Base).


%% STORE ::=
%% assign *p = q
%% | filed assign (p.f = q)
%% | array assign (arr[] = q)
%% store(DerefVar, FromVar).
%% fieldStore(BaseVar, Fld, FromVar).
%% arrayStore(Base, FromVar).

%% CALL
%% callProc(Invoc, Proc).

%% VCALL for object-orient language, base.sig()
%% vcallMethod(BaseVar, Sig, Invoc).
%% NOT used now

%% FORMALARG
%% formalArg(Proc, Nth, ParmVar).

%% ACTUALARG
%% actualArg(Invoc, Nth, ArgVar).

%% FORMALRETURN
%% formalReturn(Proc, RetVar).

%% ACTUALRETURN
%% actualReturn(Invoc, Var).
```


 
