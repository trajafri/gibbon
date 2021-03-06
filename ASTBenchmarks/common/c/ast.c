
#include "ast.h"
#include "debug.h"
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <sexp.h>
#include <sexp_ops.h>

#define STREQ(a, b)        ((strcmp(a, b) == 0))
#define TAG(tag)           STREQ(sx->val, tag)
#define NEW_AST()          (ast_t*) calloc(1, sizeof(ast_t))
#define NEW_ASTS(n)        (ast_t**) calloc(n, sizeof(ast_t))
#define FREE_AST(ast)      free(ast)
#define NEXT(sx)           sx->next; assert(sx != NULL)
#define LIST(sx)           sx->list; assert(sx != NULL)
#define LAST(sx)           assert(sx->next == NULL) 
#define SX_VALUE(sx)       assert(sx->ty == SEXP_VALUE)
#define SX_LIST(x)         assert(sx->ty == SEXP_LIST)
#define IS_SX_VALUE(sx)    ((sx && sx->ty == SEXP_VALUE))
#define IS_SX_LIST(sx)     ((sx && sx->ty == SEXP_LIST))

/*
typedef struct {
  union {
    toplvl lvl;
    expr exp;
    lvbind bnd;
    datum dat;
  } parent;
  int type;
} ctx_t;

ctx_t CTX(int parent, int type) {
  ctx_t ctx;
  ctx.parent = type;
  return ctx;
}
*/

#define TOP_AST_TYPE(typ)    g_top_ast_types[typ]
#define TOP_AST_NAME(typ)    g_top_node_types[typ]
#define EXPR_AST_TYPE(typ)   g_expr_ast_types[typ]
#define EXPR_AST_NAME(typ)   g_expr_node_types[typ]
#define FMLS_AST_TYPE(typ)   g_fmls_ast_types[typ]
#define FMLS_AST_NAME(typ)   g_fmls_node_types[typ]
#define BIND_AST_TYPE(typ)   "MKLVBIND" 
#define BIND_AST_NAME(typ)   "MKLVBIND" 
#define LAM_AST_TYPE(typ)    "MKLAMBDACASE" 
#define LAM_AST_NAME(typ)    "MKLAMBDACASE" 


const char* g_top_ast_types[] = {
  "DEFINE_VALUES", "DEFINE_SYNTAXES", "BEGINTOP", "EXPRESSION"
};

const char* g_top_node_types[] = {
  "DefineValues", "DefineSyntaxes", "BeginTop", "Expression"
};

const char* g_expr_ast_types[] = {
  "VARREF", "LAMBDA", "CASE_LAMBDA", "IF", "BEGIN", "BEGIN0", "LET_VALUES", 
  "LETREC_VALUES", "SETBANG", "QUOTE", "QUOTE_SYNTAX", "QUOTE_SYNTAX_LOCAL", 
  "WITH_CONTINUATION_MARK", "APP", "TOP", "VARIABLE_REFERENCE", 
  "VARIABLE_REFERENCE_TOP", "VARIABLE_REFERENCE_NULL"
};

const char* g_expr_node_types[] = {
  "VARREF", "Lambda", "CaseLambda", "If", "Begin", "Begin0", "LetValues", 
  "LetrecValues", "SetBang", "Quote", "QuoteSyntax", "QuoteSyntaxLocal", 
  "WithContinuationMark", "App", "Top", "VariableReference", 
  "VariableReferenceTop", "VariableReferenceNull"
};

const char* g_fmls_ast_types[] = {
  "F1", "F2", "F3"
};

const char* g_fmls_node_types[] = {
  "F1", "F2", "F3"
};

char** get_strings(sexp_t* sx, int* length) {
  sexp_t* nxt = sx; 
  do {
    nxt = nxt->next;
    (*length)++;
  } while (nxt);

  char** syms = (char**) malloc(sizeof(char*) * (*length));
  int idx = 0;
  while (idx < *length) {
    SX_VALUE(sx);
    syms[idx] = sx->val; 
    sx = sx->next;
    idx++;
  }

  return syms;
}

int get_list_length(sexp_t* sx) {
  int length = 0;
  while(sx) {
    length++;
    sx = sx->next;
  }
  return length;
}

ast_t* build_formals(sexp_t* sx /*, ctx_t ctx */) {
  if (sx) {

    ast_t* ast = NEW_AST();
    sx         = LIST(sx);
    assert(IS_SX_VALUE(sx));
    if (STREQ("F3", sx->val)) {

      ast->fmls         = F3;
      sx                = NEXT(sx);
      ast->node.fml.sym = sx->val;
      return ast;

    } else if (STREQ("F1", sx->val)) {

      int length = 0;
      ast->fmls            = F1;
      ast->node.fml.n_syms = length;
      sx                   = NEXT(sx);
      sx                   = sx->list;
      if (!sx) { // Formals with no symbols
        return ast;
      }
      assert(IS_SX_VALUE(sx));
      ast->node.fml.syms   = get_strings(sx, &length);
      ast->node.fml.n_syms = length;
      return ast;

    } else if(STREQ("F2", sx->val)) {

        int length = 0;
        ast->fmls            = F2;
        ast->node.fml.n_syms = length;
        sx           = NEXT(sx);
        sexp_t* next = sx->next;
        sx           = sx->list;
        if (sx && IS_SX_VALUE(sx)) {
          ast->node.fml.syms   = get_strings(sx, &length);
          ast->node.fml.n_syms = length;
        }

        if (next) {
          sx                = next;
          LAST(sx);
          ast->node.fml.sym = sx->val;
        }
        return ast;
    }
    // ERROR("[AST] Error building formals inside %s", AST_TYPE(ctx.parent));
    ERROR("[AST] Error building formals");
  } 
  // ERROR("[AST] Error building formals inside %s", AST_TYPE(ctx.parent));
  ERROR("[AST] Error building formals");
}

ast_t* build_quote(sexp_t* sx, ast_t* ast) {
  ast_t* chld = NEW_AST(); 
  chld->dat   = INTLIT;
  sx = NEXT(sx);
  sx = LIST(sx);
  assert(sx && IS_SX_VALUE(sx) && STREQ(sx->val, "INTLIT"));
  sx = NEXT(sx);
  chld->node.lit.data = atol(sx->val);
  ast->node.quote.exp = chld;
  return ast;
}

ast_t* build_expr(sexp_t* sx /*, ctx_t ctx */) {
  if (sx) {

    ast_t* ast = NEW_AST(); 
    if (sx->ty == SEXP_LIST) {

      sx = LIST(sx);
      assert(sx->ty == SEXP_VALUE);
      if (TAG("Lambda")) {

        ast->exp = LAMBDA;
        sx       = NEXT(sx);
        ast->node.lambda.fmls      = build_formals(sx /*, CTX(LAMBDA)*/); 
        sx       = NEXT(sx);
        sx       = LIST(sx);
        ast->node.lambda.n_exps    = get_list_length(sx);
        ast->node.lambda.exps = NEW_ASTS(ast->node.lambda.n_exps);
        for (int i=0; i < ast->node.lambda.n_exps; i++) {
          ast->node.lambda.exps[i] = build_expr(sx /*, CTX(LAMBDA) */);
          sx = sx->next;
        }
        return ast;

      } else if (TAG("CaseLambda")) {

        ast->exp = CASE_LAMBDA;
        sx       = NEXT(sx);
        sx       = LIST(sx);
        ast->node.c_lambda.n_lams    = get_list_length(sx);
        ast->node.c_lambda.lams      = NEW_ASTS(ast->node.c_lambda.n_lams);
        for (int i=0; i < ast->node.c_lambda.n_lams; i++) {
          ast->node.c_lambda.lams[i] = build_expr(sx /*, CTX(CASE_LAMBDA) */);
          sx = sx->next;
        }
        return ast;

      } else if (TAG("MKLAMBDACASE")) {

        ast->lc     = MKLAMBDACASE;
        sx          = NEXT(sx);
        ast->node.mk_lambda.fmls      = build_formals(sx /*, CTX(MKLAMBDACASE) */);
        sx                            = NEXT(sx);
        sx                            = LIST(sx);
        ast->node.mk_lambda.n_exps    = get_list_length(sx);
        ast->node.mk_lambda.exps      = NEW_ASTS(ast->node.mk_lambda.n_exps);
        for (int i=0; i < ast->node.mk_lambda.n_exps; i++) {
          ast->node.mk_lambda.exps[i] = build_expr(sx /*, CTX(MKLAMBDACASE) */);
          sx = sx->next;
        }
        return ast;
        
      } else if (TAG("VARREF")) {

        ast->exp            = VARREF;
        sx                  = NEXT(sx);
        ast->node.data.val  = sx->val;
        return ast;

      } else if (TAG("If")) {

        ast->exp = IF;
        sx       = NEXT(sx);
        ast->node.iff.cond   = build_expr(sx /*, CTX(IF) */);
        sx       = NEXT(sx);
        ast->node.iff.if_e   = build_expr(sx /*, CTX(IF) */);
        sx       = NEXT(sx);
        ast->node.iff.else_e = build_expr(sx /*, CTX(IF) */);
        return ast;

      } else if (TAG("Begin")) {

        ast->exp = BEGIN;
        sx       = NEXT(sx);
        sx       = LIST(sx);
        ast->node.begin.n_exps    = get_list_length(sx);
        ast->node.begin.exps      = NEW_ASTS(ast->node.begin.n_exps);
        for (int i=0; i < ast->node.begin.n_exps; i++) {
          ast->node.begin.exps[i] = build_expr(sx /*, CTX(BEGIN) */);
          sx = sx->next;
        }
        return ast;

      } else if (TAG("Begin0")) {

        ast->exp              = BEGIN0;
        sx                    = NEXT(sx);
        ast->node.begin0.exp  = build_expr(sx /*, CTX(BEGIN0) */);
        sx                    = sx->next;

        if (sx) {
          assert(IS_SX_LIST(sx));
          sx = sx->list;
          if (sx) {
            ast->node.begin0.n_exps    = get_list_length(sx);
            ast->node.begin0.exps      = NEW_ASTS(ast->node.begin0.n_exps);
            for (int i=0; i < ast->node.begin0.n_exps; i++) {
              ast->node.begin0.exps[i] = build_expr(sx /*, CTX(BEGIN0) */);
              sx = sx->next;
            }
          }
        }
        return ast;

      } else if (TAG("LetValues") || TAG("LetrecValues")) {

        ast->exp     = TAG("LetValues") ? LET_VALUES : LETREC_VALUES;
        sx           = NEXT(sx);
        sexp_t* nxt  = sx->next;
        sx           = sx->list;
        if (!sx) { // LetValues with zero bindings
          ast->node.let.n_binds = 0;
        } else {
          ast->node.let.n_binds    = get_list_length(sx);
          ast->node.let.binds      = NEW_ASTS(ast->node.let.n_binds);
          for (int i=0; i < ast->node.let.n_binds; i++) {
            ast->node.let.binds[i] = build_expr(sx /*, CTX(LET_VALUES) */);
            sx = sx->next;
          }
        }
        nxt = LIST(nxt);
        ast->node.let.n_exps    = get_list_length(nxt);
        ast->node.let.exps      = NEW_ASTS(ast->node.let.n_exps);
        for (int i=0; i < ast->node.let.n_exps; i++) {
          ast->node.let.exps[i] = build_expr(nxt /*, CTX(LET_VALUES) */);
          nxt = nxt->next;
        }
        return ast;

      } else if (TAG("MKLVBIND")) {

        ast->bnd     = MKLVBIND;
        sx           = NEXT(sx);
        sexp_t* nxt  = sx->next;
        sx           = sx->list;
        int length   = 0;
        if (sx) {
          ast->node.binder.syms   = get_strings(sx, &length);
        } 
        ast->node.binder.exp    = build_expr(nxt /*, CTX(MKLVBIND) */);
        ast->node.binder.n_syms = length;
        return ast;
        
      } else if (TAG("SetBang")) {

        ast->exp           = SETBANG;
        sx                 = NEXT(sx);
        assert(IS_SX_VALUE(sx));
        ast->node.set.sym  = sx->val;
        sx                 = NEXT(sx);
        ast->node.set.exp  = build_expr(sx /*, CTX(SETBANG) */);
        return ast;

      } else if (TAG("Quote") || TAG("QuoteSyntax") || 
          TAG("QuoteSyntaxLocal")) {

        if (TAG("Quote")) {
          ast->exp = QUOTE;
        } else if (TAG("QuoteSyntax")) {
          ast->exp = QUOTE_SYNTAX;
        } else {
          ast->exp = QUOTE_SYNTAX_LOCAL;
        }
        build_quote(sx, ast);

      } else if (TAG("WithContinuationMark")) {

        ast->exp = WITH_CONTINUATION_MARK;
        sx       = NEXT(sx);
        ast->node.wcm.key = build_expr(sx /*, CTX(WITH_CONTINUATION_MARK) */);
        sx       = NEXT(sx);
        ast->node.wcm.val = build_expr(sx /*, CTX(WITH_CONTINUATION_MARK) */);
        sx       = NEXT(sx);
        ast->node.wcm.res = build_expr(sx /*, CTX(WITH_CONTINUATION_MARK) */);
        return ast;

      } else if (TAG("App")) {

        ast->exp = APP;
        sx       = NEXT(sx);
        sx       = LIST(sx);
        ast->node.app.n_exps    = get_list_length(sx);
        ast->node.app.exps      = NEW_ASTS(ast->node.app.n_exps);
        for (int i=0; i < ast->node.app.n_exps; i++) {
          ast->node.app.exps[i] = build_expr(sx /*, CTX(APP) */);
          sx = sx->next;
        }
        return ast;

      } else if (TAG("Top") || TAG("VariableReference") || 
          TAG("VariableReferenceTop")) {

        ast->exp = TAG("Top") ? TOP : 
          (TAG("VariableReference") ? VARIABLE_REFERENCE :
           VARIABLE_REFERENCE_TOP);
        sx                 = NEXT(sx);
        assert(IS_SX_VALUE(sx));
        ast->node.data.val = sx->val;
        return ast;

      } else if (TAG("VariableReferenceNull")) {

        ast->exp           = VARIABLE_REFERENCE_NULL;
        ast->node.data.val = NULL;
        return ast;

      } else {
        ERROR("[AST] Error building expression.."); 
      }  
    } else {
      ERROR("[AST] Error building expression.."); 
    }
  }
}

ast_t* build_top_lvl(sexp_t* sx) {
  if (IS_SX_LIST(sx)) {

    sx = LIST(sx);
    if (IS_SX_VALUE(sx)) {

      if (TAG("Expression")) { // (#%expression expr)

        ast_t* expr              = NEW_AST();
        expr->tl                 = EXPRESSION;
        sx                       = NEXT(sx);
        expr->node.expr.exp      = build_expr(sx /*, CTX(EXPRESSION) */);
        return expr;
          
      } else if (TAG("DefineValues") || TAG("DefineSyntaxes")) {

        ast_t* expr = NEW_AST();
        expr->tl    = TAG("DefineValues") ? DEFINE_VALUES : DEFINE_SYNTAXES;
        sx          = NEXT(sx);
        sexp_t* nxt = sx->next;
        sx          = sx->list;
        int length  = 0;
        if (sx) {
          expr->node.defs.syms     = get_strings(sx, &length);
        }
        expr->node.defs.exp      = build_expr(nxt /*, CTX(expr->ty) */);
        expr->node.defs.n_syms   = length;
        return expr;

      } else if (TAG("BeginTop")) {
        ast_t* expr = NEW_AST();
        expr->tl    = BEGINTOP;
        sx          = sx->next;
        if (sx && sx->list) {
          sx          = LIST(sx);
          expr->node.prog.n_tops      = get_list_length(sx);
          expr->node.prog.toplvl      = NEW_ASTS(expr->node.prog.n_tops);
          for (int i=0; i < expr->node.prog.n_tops; i++) {
            expr->node.prog.toplvl[i] = build_top_lvl(sx);
            sx = sx->next;
          }
        }
        return expr;
      } else {
        ERROR("[AST] Error building top inside root..");
      }
    } else {
      ERROR("[AST] Error building top inside root..");
    }
  } else if (IS_SX_VALUE(sx)) {
    ERROR("[AST] Error building top inside root..");
  }
  ERROR("[AST] Error building top inside root..");
}

ast_t* build_ast(void* parse_tree) {
  sexp_t* sx = (sexp_t*) parse_tree;
  return build_top_lvl(sx);
}

void print_expression(FILE* fp, ast_t* ast);
  
void print_formals(FILE* fp, ast_t* ast) {
  fprintf(fp, "(%s ", FMLS_AST_NAME(ast->fmls));
  if (ast->fmls == F1 || ast->fmls == F2) {
    fprintf(fp, "(");
    for (int i=0; i < ast->node.fml.n_syms; i++) {
      fprintf(fp, "%s", ast->node.fml.syms[i]);
      if (i < ast->node.fml.n_syms - 1) {
        fprintf(fp, " ");
      }
    } 
    fprintf(fp, ")");
  }

  if (ast->node.fml.sym) {
    if (ast->fmls == F2) {
      fprintf(fp, " ");
    }
    fprintf(fp, "%s", ast->node.fml.sym);
  }
  fprintf(fp, ")");
}

void print_let_binds(FILE* fp, ast_t* ast) {
  fprintf(fp, "(%s ", BIND_AST_NAME(ast->bnd));
  fprintf(fp, "(");
  for (int i=0; i < ast->node.binder.n_syms; i++) {
    fprintf(fp, "%s", ast->node.binder.syms[i]);
    if (i < ast->node.binder.n_syms - 1) {
      fprintf(fp, " ");
    }
  }
  fprintf(fp, ")");
  fprintf(fp, " ");
  print_expression(fp, ast->node.binder.exp);
  fprintf(fp, ")");
}

void print_lambda_case(FILE* fp, ast_t* ast) {
  assert(ast->lc == MKLAMBDACASE);
  fprintf(fp, "(%s ", LAM_AST_NAME(ast->lc));
  print_formals(fp, ast->node.mk_lambda.fmls);
  fprintf(fp, "(");
  for (int i=0; i < ast->node.mk_lambda.n_exps; i++) {
    print_expression(fp, ast->node.mk_lambda.exps[i]);
    if (i < ast->node.mk_lambda.n_exps - 1) {
      fprintf(fp, " ");
    }
  } 
  fprintf(fp, ")");
  fprintf(fp, ")");
}

void print_expression(FILE* fp, ast_t* ast) {
  fprintf(fp, "(%s ", EXPR_AST_NAME(ast->exp));
  switch (ast->exp) {
    case VARREF:
      fprintf(fp, "%s", ast->node.data.val);
      break;
    case LAMBDA:
      print_formals(fp, ast->node.lambda.fmls);
      fprintf(fp, " ");
      fprintf(fp, "(");
      for (int i=0; i < ast->node.lambda.n_exps; i++) {
        print_expression(fp,  ast->node.lambda.exps[i]);
      }
      fprintf(fp, ")");
      break;
    case CASE_LAMBDA:
      fprintf(fp, "(");
      for (int i=0; i < ast->node.c_lambda.n_lams; i++) {
        print_lambda_case(fp, ast->node.c_lambda.lams[i]);
        if (i < ast->node.c_lambda.n_lams - 1) {
          fprintf(fp, " ");
        }
      }
      fprintf(fp, ")");
      break;
    case IF:
      print_expression(fp, ast->node.iff.cond);
      fprintf(fp, " ");
      print_expression(fp, ast->node.iff.if_e);
      fprintf(fp, " ");
      print_expression(fp, ast->node.iff.else_e);
      break;
    case BEGIN:
      fprintf(fp, "(");
      for (int i=0; i < ast->node.begin.n_exps; i++) {
        print_expression(fp, ast->node.begin.exps[i]);
        if (i < ast->node.begin.n_exps - 1) {
          fprintf(fp, " ");
        }
      }
      fprintf(fp, ")");
      break;
    case BEGIN0:
      print_expression(fp, ast->node.begin0.exp);
      fprintf(fp, " ");
      fprintf(fp, "(");
      for (int i=0; i < ast->node.begin0.n_exps; i++) {
        print_expression(fp, ast->node.begin0.exps[i]);
        if (i < ast->node.begin0.n_exps - 1) {
          fprintf(fp, " ");
        }
      }
      fprintf(fp, ")");
      break;
    case LET_VALUES:
    case LETREC_VALUES:
      fprintf(fp, "(");
      for (int i=0; i < ast->node.let.n_binds; i++) {
        print_let_binds(fp, ast->node.let.binds[i]);
        if (i < ast->node.let.n_binds - 1) {
          fprintf(fp, " ");
        }
      }
      fprintf(fp, ")");

      fprintf(fp, " ");
      fprintf(fp, "(");
      for (int i=0; i < ast->node.let.n_exps; i++) {
        print_expression(fp, ast->node.let.exps[i]);
        if (i < ast->node.let.n_exps - 1) {
          fprintf(fp, " ");
        }
      }
      fprintf(fp, ")");
      break;
    case SETBANG:
      fprintf(fp, "%s ", ast->node.set.sym);
      print_expression(fp, ast->node.set.exp);
      break;
    case QUOTE:
    case QUOTE_SYNTAX:
    case QUOTE_SYNTAX_LOCAL: 
      fprintf(fp, "(INTLIT ");
      fprintf(fp, "%ld", ast->node.quote.exp->node.lit.data);
      fprintf(fp, ")");
      break;
    case WITH_CONTINUATION_MARK:
      print_expression(fp, ast->node.wcm.key);
      fprintf(fp, " ");
      print_expression(fp, ast->node.wcm.val);
      fprintf(fp, " ");
      print_expression(fp, ast->node.wcm.res);
      break;
    case APP:
      fprintf(fp, "(");
      for (int i=0; i < ast->node.app.n_exps; i++) {
        print_expression(fp, ast->node.app.exps[i]);
        if (i < ast->node.app.n_exps - 1) {
          fprintf(fp, " ");
        }
      }
      fprintf(fp, ")");
      break;
    case TOP:
    case VARIABLE_REFERENCE:
    case VARIABLE_REFERENCE_TOP:
      fprintf(fp, "%s", ast->node.data.val);
      break;
    case VARIABLE_REFERENCE_NULL:
      break;
    default:
      ERROR("[AST-PRINT] Invalid expression..");
  }
  fprintf(fp, ")");
}

void print_top_lvl(FILE* fp, ast_t* ast) {
  fprintf(fp, "(%s ", TOP_AST_NAME(ast->tl));
  switch (ast->tl) {
    case DEFINE_VALUES:
    case DEFINE_SYNTAXES:
      fprintf(fp, "(");
      for (int i=0; i < ast->node.defs.n_syms; i++) {
        fprintf(fp, "%s", ast->node.defs.syms[i]);
        if (i < ast->node.defs.n_syms - 1) {
          fprintf(fp, " ");
        }
      }
      fprintf(fp, ")");
      fprintf(fp, " ");
      print_expression(fp, ast->node.defs.exp);
      break;
    case BEGINTOP:
      fprintf(fp, "(");
      for (int i=0; i < ast->node.prog.n_tops; i++) {
        print_top_lvl(fp, ast->node.prog.toplvl[i]);
        if (i < ast->node.prog.n_tops - 1) {
          fprintf(fp, " ");
        }
      }
      fprintf(fp, ")");
      break;
    case EXPRESSION:
      print_expression(fp, ast->node.expr.exp);
      break;
    default:
      ERROR("[AST-PRINT] Invalid top level element..");
  }
  fprintf(fp, ")");
}

void print_ast(ast_t* ast, char* fname) {
  if (ast) {
    FILE* fp = fopen(fname,"w+");
    if (fp <= 0) {
      ERROR("[AST] Error opening the file");
    }
    print_top_lvl(fp, ast);
    fprintf(fp, "\n");
    fclose(fp);
  }
}
