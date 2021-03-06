%% module must be the first directive, and must appear just once.
%% :- module(preprocessing, [build/1, relationGen/1]).

:- use_module(library(semweb/rdf_db)).
:- use_module(library(semweb/rdf_ntriples)).

:- dynamic heapLoc/2, stackLoc/2, copy/2,
	load/2, fieldLoad/3, arrayLoad/2,
	store/2, fieldStore/3, arrayStore/2,
	callProc/2, formalArg/3, actualArg/3,
	formalReturn/2, actualReturn/2.

%% ------------------------------
%% public APIs
%% ------------------------------

:- initialization autoBuild.

% For running this module as top script, i.e.,
% $swipl preprocessing.pl Input.trp
autoBuild :-
	current_prolog_flag(argv, Arguments),
	[Inputfile|_] = Arguments,
	access_file(Inputfile, exist), % check file exist
	rdf_load(Inputfile, [format(ntriples)]),
	file_base_name(Inputfile, BaseName), % strip path 
	atom_concat(BaseName, '.pl', Outputfile),
	build(Outputfile), halt(0).

% For calling as predicate 
% Produce all the relations and optionally
% output the generated relations to file
% ?Out: output file name out.pl OR uninitialized (in-memory)
build(Out) :-
	forall(relationGen(_), put('.')), nl,
	write('Successfully produce the relations'), nl,
	(atom(Out) ->
	telling(Old), tell(Out),
	forall(member(P, [heapLoc, stackLoc, copy,
		load, fieldLoad, arrayLoad,
		store, fieldStore, arrayStore,
		callProc, formalArg, actualArg,
		formalReturn, actualReturn]), listing(P)),
	write('%%'), nl,
	told, tell(Old)
	; writeln('in-memory database')
	).

%% ------------------------------
%% relation build helper
%% ------------------------------

%% List is a list of [Relation, Arg1, Arg2, ...]
%% e.g., [copy, toVar, FromVar]
insertFact(List) :-
	Fact =.. List,
	%% write(Fact), nl,
	assertz(Fact).

%% ------------------------------
%% Main predicates to generate relations
%% ------------------------------

%% $
%% assignment
relationGen(assignment) :-
	assign(LHS, RHS), %% scan assignments
	%% write(LHS), write('---'), nl, %% only for debug
	parseLHS(LHS, ToRef, Relation), %% return ToRef and Relation
	parseRHS(RHS, RHSINode), %% return temp node
	%% Relation(ToRef, RHSINode)
	append([Relation|ToRef], [RHSINode], Constrain),
	insertFact(Constrain).

%% $
%% initialization
%% @tbd more complex parse init list
%% OR split int p = ... to int p; p = ...
relationGen(initialization) :-
	rdf(Decl, hasInit, Initializer),
	parseRHS(Initializer, RHSINode),
	insertFact([copy, Decl, RHSINode]).

%% $
%% An aggregate type is an array or a class type (struct, union, or class)
%% treat struct as object, so its declaration as malloc
%% treat array declaration as malloc
relationGen(aggregateDecl) :-
	rdf(Decl, hasTypeClass, literal('AggregateType')),
	atom_concat(heap, Decl, HeapDecl),
	insertFact([heapLoc, Decl, HeapDecl]).

%% $
%% function declaration
relationGen(functionDecl) :-
	rdf(Proc, isa, literal('Function')),
	(procFormalArg(Proc); procFormalReturn(Proc)).

%% $
relationGen(functionCall) :-
	rdf(Invoc, isa, literal('CallExpr')),
	callRelation(Invoc).

%% ------------------------------
%% Some syntax helper
%% ------------------------------

%% +Expr
alloc(Expr, Heap) :-
	(
		rdf(Expr, calls, literal('malloc'));
		rdf(Expr, calls, literal('alloca'));
		rdf(Expr, calls, literal('calloc'))
	), atom_concat(heap, Expr, Heap). %% Heap is abstracted by callsite

%%
assign(LHS, RHS) :-
	rdf(Bop, hasOperator, literal('=')),
	rdf(Bop, hasLHS, LHS),
	rdf(Bop, hasRHS, RHS).

%% +Proc
procFormalArg(Proc) :-
	rdf(Proc, HasParm, ParmVar),
	rdf(ParmVar, isa, literal('ParmVar')),
	atom_concat('hasParm(', X, HasParm),
	atom_concat(Nth, ')', X),
	insertFact(['formalArg', Proc, Nth, ParmVar]).

%% +Proc
procFormalReturn(Proc) :-
	rdf(Return, isa, literal('ReturnStmt')),
	rdf(Return, inProc, Proc),
	rdf(Return, returns, RetExpr),
	parseRHS(RetExpr, RHSINode),
	insertFact(['formalReturn', Proc, RHSINode]).

%% +Invoc
callRelation(Invoc) :-
	rdf(Invoc, callsFunc, ProcDecl),
	rdf(Proc, hasCanonicalDecl, ProcDecl), rdf(Proc, isa, literal('Definition')), % get the definition instead of declaration
	insertFact([callProc, Invoc, Proc]),
	rdf(Invoc, HasArg, ArgExpr),
	atom_concat('hasArg(', X, HasArg),
	atom_concat(Nth, ')', X),
	%% parse ArgExpr
	%% func(ArgExpr) => (INode = ArgExpr), func(INode)
	parseRHS(ArgExpr, RHSINode),
	insertFact(['actualArg', Invoc, Nth, RHSINode]).

%% ------------------------------
%% ParseLHS
%% ------------------------------
%% determine the relation based on LHS format
parseLHS(LHS, ToRef, Relation) :-
	(
		%% a = 
		rdf(LHS, isa, literal('DeclRefExpr'))
		-> Relation = copy, rdf(LHS, hasDecl, Decl),	ToRef = [Decl]
		%% dereference *a = 
		; rdf(LHS, isa, literal('UnaryOperator')), 
		rdf(LHS, hasOperator, literal('*'))
		-> Relation = store, rdf(LHS, hasSubExpr, DerefVarRef), rdf(DerefVarRef, hasDecl, DerefVar), ToRef = [DerefVar]
		%% member s.f = ...
		; rdf(LHS, isa, literal('MemberExpr'))
		-> Relation = fieldStore, rdf(LHS, hasBase, BaseExpr), rdf(LHS, hasMemberDecl, FldDecl), rdf(BaseExpr, hasDecl, BaseVar), ToRef = [BaseVar, FldDecl]
		%% subscript a[i] = ...
		; rdf(LHS, isa, literal('ArraySubscriptExpr'))
		-> Relation = arrayStore, rdf(LHS, hasBase, BaseExpr), rdf(BaseExpr, hasDecl, BaseVar), ToRef = [BaseVar]
	).

%% ------------------------------
%% ParseRHS
%% ------------------------------
%% ``LHS = RHS'' is first split to
%% LHS = tmp; tmp = RHS
%% tmp is regarded as normal reference (keep transition)
%% e.g., *p = *q or s.f = t.q ...

%% +RHS -RHSINode
%% = alloc()
parseRHS(RHS, RHSINode) :-
	alloc(RHS, Heap),
	atom_concat(tmp, RHS, RHSINode),
	insertFact([heapLoc, RHSINode, Heap]), !.

%% = &X
parseRHS(RHS, RHSINode) :-
	rdf(RHS, hasOperator, literal('&')),
	rdf(RHS, hasSubExpr, LocRef),
	rdf(LocRef, hasDecl, Var),
	atom_concat(tmp, RHS, RHSINode),
	insertFact([stackLoc, RHSINode, Var]), !.

%% = ref
parseRHS(RHS, RHSINode) :-
	rdf(RHS, isa, literal('DeclRefExpr')),
	rdf(RHS, hasDecl, Var),
	RHSINode = Var, !.

%% = *ref
parseRHS(RHS, RHSINode) :-
	rdf(RHS, hasOperator, literal('*')),
	rdf(RHS, hasSubExpr, DerefVarRef),
	atom_concat(tmp, RHS, RHSINode),
	rdf(DerefVarRef, hasDecl, DerefVar),
	insertFact([load, RHSINode, DerefVar]), !.

%% = ref.fld, ref->fld
parseRHS(RHS, RHSINode) :-
	rdf(RHS, isa, literal('MemberExpr')),
	rdf(RHS, hasBase, BaseRef),
	rdf(BaseRef, hasDecl, Base),
	rdf(RHS, hasMemberDecl, FldDecl),
	atom_concat(tmp, RHS, RHSINode),
	insertFact([fieldLoad, RHSINode, Base, FldDecl]), !.

%% = ref[]
parseRHS(RHS, RHSINode) :-
	rdf(RHS, isa, literal('ArraySubscriptExpr')),
	rdf(RHS, hasBase, BaseRef),
	rdf(BaseRef, hasDecl, Base),
	atom_concat(tmp, RHS, RHSINode),
	insertFact([arrayLoad, RHSINode, Base]), !.

%% CallExpr
%% = tmp; tmp = invoc();
%% tmp is abstracted by callsite/invocation
parseRHS(RHS, RHSINode) :-
	rdf(RHS, isa, literal('CallExpr')),
	atom_concat(tmp, RHS, RHSINode), %% only a tmp node
	insertFact(['actualReturn', RHS, RHSINode]).


%% ------------------------------
%% Unused, as backup for improvement
%% ------------------------------

%% @tdb
%% check type of expression
%% checkType(LHS, Type) :- nl.

%% A more complicated alternative
%% recursively parse the RHS by introducing more temporary variables
%% RHS ::= refExpr | &(refExpr) | *refExpr | refExpr.f | refExpr[]
%% refExpr ::= 'DeclRefExpr' | alloc | callExpr | RHS
recursiveParseRHS(RHS, INode) :-
	rdf(RHS, isa, literal('DeclRefExpr')),
	rdf(RHS, hasDecl, Var),
	INode = Var, !.

%% alloc
recursiveParseRHS(RHS, INode) :-
	alloc(RHS, Heap),
	atom_concat(tmp, RHS, INode),
	insertFact([heapLoc, INode, Heap]), !.

%% call
recursiveParseRHS(RHS, INode) :-
	rdf(RHS, isa, literal('CallExpr')),
	atom_concat(tmp, RHS, INode),
	insertFact(['actualReturn', RHS, INode]), !.

%% = &Expr => = INode; stackLoc(INode, INode2);
%% (INode2 = Expr)
recursiveParseRHS(RHS, INode) :-
	rdf(RHS, hasOperator, literal('&')),
	rdf(RHS, hasSubExpr, Sub),
	atom_concat(tmp, RHS, INode),
	recursiveParseRHS(Sub, INode2),
	insertFact([stackLoc, INode, INode2]).

%% = *Expr => (INode2 = Expr); load(INode, INode2)
recursiveParseRHS(RHS, INode) :-
	rdf(RHS, hasOperator, literal('*')),
	rdf(RHS, hasSubExpr, Sub),
	atom_concat(tmp, RHS, INode),
	recursiveParseRHS(Sub, INode2),
	insertFact([load, INode, INode2]).

%% = refExpr.fld => (INode2 = refExpr);
%% fieldLoad(INode, INode2, fld)
recursiveParseRHS(RHS, INode) :-
	rdf(RHS, isa, literal('MemberExpr')),
	rdf(RHS, hasBase, BaseRef),
	rdf(RHS, hasMemberDecl, FldDecl),
	atom_concat(tmp, RHS, INode),
	recursiveParseRHS(BaseRef, INode2),
	insertFact([fieldLoad, INode, INode2, FldDecl]).

%% = refExpr[] => (INode2 = refExpr);
%% arrayLoad(INode, INode2)
recursiveParseRHS(RHS, INode) :-
	rdf(RHS, isa, literal('ArraySubscriptExpr')),
	rdf(RHS, hasBase, BaseRef),
	atom_concat(tmp, RHS, INode),
	recursiveParseRHS(BaseRef, INode2),
	insertFact([arrayLoad, INode, INode2]).


%% to do
% function pointer
% multi dim array
% type check and filter
