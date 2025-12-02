%{
#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <sstream>
#include <algorithm>

using namespace std;

int linha = 1, coluna = 1; 

int in_func = 0; // Contador de níveis de função (para permitir referência a variáveis externas não declaradas)

struct Atributos {
  vector<string> c; // Código

  int linha = 0, coluna = 0;

  int n_args = 0; // Número de argumentos em chamadas de função
  int contador = 0; // Contador de parâmetros
  vector<string> valor_default; // Coletar valores default de parâmetros

  vector<string> esq; // Valor usado em LVP, para separar E[ E ].
  vector<string> dir; // Valor usado em LVP, sempre variáveis temporárias

  void clear() {
    c.clear();
    valor_default.clear();
    linha = 0;
    coluna = 0;
    contador = 0;
  }
};


#define YYSTYPE Atributos

extern "C" int yylex();
int yyparse();
void yyerror( const char* st );


vector<string> concatena( vector<string> a, vector<string> b ) {
  a.insert( a.end(), b.begin(), b.end() );
  return a;
}

vector<string> operator+( vector<string> a, vector<string> b ) {
  return concatena( a, b );
}

vector<string>& operator+=( vector<string>& a, const vector<string>& b ) {
  a.insert( a.end(), b.begin(), b.end() );
  return a;
}

vector<string> operator+( vector<string> a, string b ) {
  a.push_back( b );
  return a;
}

vector<string>& operator+=( vector<string>& a, const string& b ) {
  a.push_back( b ); 
  return a;
}

vector<string> operator+( string a, vector<string> b ) {
  return vector<string>{ a } + b;
}


enum TipoDecl { Let = 1, Const, Var };

struct Simbolo {
  TipoDecl tipo;
  int linha;
  int coluna;
  bool isFunc = false;
};

// Tabela de símbolos
vector< map< string, Simbolo > > ts = { { } };
// .back() é o escopo atual

Atributos declara_variavel( TipoDecl decl, Atributos atrib, int linha, int coluna ) {
  string nome_var = atrib.c[0];
  
  // cerr << "DEBUG declara_variavel: var=" << nome_var << " in scope " << (ts.size() - 1) << " (ts.size()=" << ts.size() << ")" << endl;

  if (decl == Var){
    if (ts.back().count(nome_var) > 0){
      if (ts.back()[nome_var].tipo != Var){
         cerr <<  "Erro: a variável '" << nome_var << "' já foi declarada na linha " << ts.back()[nome_var].linha << "." << endl;
         exit(1);
      }
      else {
        atrib.c.clear();
        return atrib;
      }
    }
  }
  else if (ts.back().count(nome_var) > 0){
    cerr << "Erro: a variável '" << nome_var << "' já foi declarada na linha " << ts.back()[nome_var].linha << "." << endl;
    exit(1);
  }
  
  ts.back()[nome_var].linha = atrib.linha;
  ts.back()[nome_var].coluna = atrib.coluna;
  ts.back()[nome_var].tipo = decl;

  atrib.c = atrib.c + "&";
  return atrib;
}

const string JUMP = "#";
const string JUMP_TRUE = "?";
const string POP = "^";
const string callFunc = "$";


vector<string> resolve_enderecos( vector<string> entrada ) {
  map<string,int> label;
  vector<string> saida;
  for( int i = 0; i < entrada.size(); i++ ) 
    if( entrada[i][0] == ':' ) 
        label[entrada[i].substr(1)] = saida.size();
    else
      saida.push_back( entrada[i] );
  
  for( int i = 0; i < saida.size(); i++ ) 
    if( label.count( saida[i] ) > 0 )
        saida[i] = to_string(label[saida[i]]);
    
  return saida;
}

string gera_label( string prefixo ) {
  static int n = 0;
  return prefixo + "_" + to_string( ++n ) + ":";
}

string define_label( string prefixo ) {
  return ":" + prefixo;
}

void print( vector<string> codigo ) {
  for( string s : codigo )
    cout << s << " ";
  cout << endl;  
}

vector<string> funcoes; // Acumula o código de todas funções

vector<int> alinhamento_return; // Pilha de alinhamento por função: topo guarda quantos blocos '{ }' estão abertos

string gera_temp( string nome ) {
  static int t = 0;
  return string("temp_") + nome + to_string(++t);
}


vector<set<string>> variavel_capturada; // Pilha de conjuntos de variáveis capturadas
vector<int> escopo_base_lambda;

// Determina se deve ou não capturar uma variável
void trata_captura(string var) {
  if (variavel_capturada.empty()) return;
  
  // 1. Se a variável está no escopo local (topo), não captura.
  if (ts.back().count(var) > 0) return; 
  
  // 2. Procura apenas nos escopos INTERMEDIÁRIOS (ignora Global no índice 0)
  //    Isso garante que globais como 'k' nunca sejam capturadas.
  for (int i = 1; i < (int)ts.size() - 1; i++) {
    if (ts[i].count(var) > 0) {
      // Se for função, não captura
      if (ts[i][var].isFunc) return; 
      
      // Se achou a variável no escopo 'i', verifica em quais lambdas ela precisa ser capturada
      for (int j = 0; j < variavel_capturada.size(); j++) {
        // Só captura se a variável foi definida em um escopo ANTERIOR à criação da lambda
        if (i < escopo_base_lambda[j]) {
           variavel_capturada[j].insert(var);
        }
      }
      return; 
    }
  }
  // Se chegou aqui, ou é global (índice 0) ou não existe. Não captura.
}

void empilha_variavel_capturada() {
  variavel_capturada.push_back(set<string>());
}

void desempilha_variavel_capturada() {
  if (!variavel_capturada.empty()) {
    variavel_capturada.pop_back();
  }
}

set<string> capturas_atuais() {
  return variavel_capturada.empty() ? set<string>() : variavel_capturada.back();
}


// Gera código para criar o campo captura com as variáveis
vector<string> gera_codigo_captura(const set<string>& capturas) {
  // Modelo: f & f {} = '&funcao' 73 [<=] captura {} x x @ [<=] [<=] .

  if (capturas.empty()) {
    return vector<string>();
  }
  
  vector<string> codigo;
  // Cria campo 'captura' como objeto vazio
  codigo += "captura";
  codigo += "{}";
  
  // Para cada variável capturada, adiciona ao objeto captura
  for (const string& var : capturas) {
    codigo += var;
    codigo += var;
    codigo += "@";
    codigo += "[<=]";
  }
  
  codigo += "[<=]"; // Atribui o objeto captura à função
  
  return codigo;
}


void checa_simbolo( string nome, bool modificavel ) {

  trata_captura(nome); // Verifica se a variável deve ser capturada

  for( int i = (int)ts.size() - 1; i >= 0; --i ) {
    auto& esc = ts[i];
    auto it = esc.find(nome);
    if (it != esc.end()) {
      if (modificavel && it->second.tipo == Const) {
        cerr << "Erro: tentativa de modificar uma variável constante ('" << nome << "')." << endl;
        exit(1);
      }
      return;
    }
  }

  // Permite referência a variáveis externas ainda não declaradas quando dentro de função (leitura)
  if (in_func > 0) {
    return; // será resolvido em tempo de execução
  }

  cerr << "Erro: a variável '" << nome << "' não foi declarada." << endl;
  // fprintf( stderr, "Erro: a variável '%s' não foi declarada na linha %d, coluna %d.\n", nome_var.c_str(), atrib.linha, atrib.coluna );
  exit( 1 );     
}

vector<string> pilha_arrays;   // Guarda o nome da variável do array
vector<int> pilha_indices;     // Guarda o índice atual sendo preenchido

void empilha_array(string nome) {
  pilha_arrays.push_back(nome);
  pilha_indices.push_back(0);
}

void desempilha_array() {
  if (!pilha_arrays.empty()) {
    pilha_arrays.pop_back();
    pilha_indices.pop_back();
  }
}

string nome_array_atual() {
  return pilha_arrays.empty() ? "" : pilha_arrays.back();
}

int indice_array_atual() {
  return pilha_indices.empty() ? 0 : pilha_indices.back();
}

void incrementa_indice_array() {
  if (!pilha_indices.empty()) {
    pilha_indices.back()++;
  }
}

%}

%token ID LET CONST VAR
%token IF ELSE FOR WHILE 
%token FUNCTION RETURN ASM
%token TRUE FALSE
%token CDOUBLE CSTRING CINT
%token AND OR ME_IG MA_IG DIF IGUAL
%token MAIS_IGUAL MAIS_MAIS MENOS_IGUAL MENOS_MENOS
%token SETA FPL
// FPL = Fecha Parênteses Lambda - se precisa de comentário para explicar o nome da variável, é porque isso nõ tá bom

%right ','
%left ':'
%right '=' MAIS_IGUAL MENOS_IGUAL SETA '?'
%left OR
%left AND
%nonassoc '<' '>' ME_IG MA_IG IGUAL DIF
%left '+' '-'
%left '*' '/' '%'
%left '.' 
%left MAIS_MAIS MENOS_MENOS
%left ASM

%%

S : CMDs { print( resolve_enderecos( $1.c + "." + funcoes ) ); }
  ;

CMDs : CMD CMDs { $$.c = $1.c + $2.c; };
     | CMD
     ;

// ; faz parte do comando, bloco por exemplo não termina com ;
CMD : DECL ';'
    | ECOND ';' { $$.c = $1.c + "^"; }
    | CMD_IF
    | CMD_FOR
    | CMD_WHILE
    | ';' { $$.clear(); } // comando vazio
    | CMD_FUNC 
    | CMD_RETURN
    | BLOCO
    ;

BLOCO : '{' EMPILHA_TS { if (!alinhamento_return.empty()) alinhamento_return.back()++; } CMDs '}' // Empilha escopo novo
       { if (!alinhamento_return.empty()) alinhamento_return.back()--; ts.pop_back(); $$.c = "<{" + $4.c + "}>"; }
      | '{' '}' { $$.c = vector<string>{"<{", "}>"}; }
      ;

BLOCO_FUNC : '{' CMDs '}' 
           { $$.c = $2.c; }
           | '{' '}' { $$.c = vector<string>{}; }
           ;

DECL : LET LET_IDs { $$.c = $2.c; }
     | CONST CONST_IDs { $$.c = $2.c; }
     | VAR VAR_IDs {$$.c = $2.c;}
     ;
           
LET_IDs: LET_UM_ID ',' LET_IDs
        { $$.c = $1.c + $3.c; }
        | LET_UM_ID
        ;

LET_UM_ID : ID { $$ = declara_variavel( Let, $1, $1.linha, $1.coluna); }
          | ID '=' { empilha_array($1.c[0]); } EOBJ 
            { desempilha_array();
              $$ = declara_variavel( Let, $1, $1.linha, $1.coluna); 
              $$.c = $$.c + $1.c + $4.c + "=" + "^"; }
          ;


CONST_IDs : CONST_UM_ID ',' CONST_IDs
            { $$.c = $1.c + $3.c; }
            | CONST_UM_ID
            ;

CONST_UM_ID : ID {$$ = declara_variavel ( Const, $1, $1.linha, $1.coluna); }
            | ID '=' { empilha_array($1.c[0]); } EOBJ 
              { desempilha_array();
                $$ = declara_variavel( Const, $1, $1.linha, $1.coluna); 
                $$.c = $$.c + $1.c + $4.c + "=" + "^"; }
            ;


VAR_IDs : VAR_UM_ID ',' VAR_IDs
        { $$.c = $1.c + $3.c; }
        | VAR_UM_ID
        ;

VAR_UM_ID : ID { $$ = declara_variavel( Var, $1, $1.linha, $1.coluna ); }
          | ID '=' { empilha_array($1.c[0]); } EOBJ 
            { desempilha_array();
              $$ = declara_variavel( Var, $1, $1.linha, $1.coluna); 
              $$.c = $$.c + $1.c + $4.c + "=" + "^"; }
          ;

CMD_IF : IF '(' EOBJ ')' CMD
         { string fim_if = gera_label("fim_if");
           $$.c = $3.c + "!" + fim_if  + "?" + $5.c + define_label(fim_if);
         }
       | IF '(' EOBJ ')' CMD ELSE CMD
         { string fim_if = gera_label("fim_if");
           string else_if = gera_label("else");

           $$.c = $3.c + "!" + else_if + "?" + // Expressão
           $5.c + fim_if + "#" +               // Comando do if  
           define_label(else_if) + $7.c +      // Else
           define_label(fim_if);               // fim if
         }
      ;

CMD_FOR : FOR '(' SF ';' EOBJ ';' EF ')' CMD
         { string teste_for = gera_label("teste_for");
           string fim_for = gera_label("fim_for");

           $$.c = $3.c +                             // Atribuição inicial           
           define_label(teste_for) + $5.c +          // Teste do for
           "!" + fim_for + JUMP_TRUE +               // jump
           $9.c +                                    // Comando
           $7.c +                                    // Efeitos
           teste_for + JUMP +                        // Volta para o início
           define_label(fim_for);                    // Fim do for
         }
       ;

EF : EOBJ {$$.c = $1.c + "^";}
   | {$$.clear();}
   ;
// SEMPRE QUE TIVER UMA EXPRESSÃO VAZIA, PRECISA DE UM $$.clear()

SF : DECL
   | EF
   ;

CMD_WHILE : WHILE '(' EOBJ ')' CMD
           { string teste_while = gera_label("teste_while");
             string fim_while = gera_label("fim_while");

             $$.c = define_label(teste_while) + $3.c +  // Início do while
             "!" + fim_while + JUMP_TRUE +              // Expressão
             $5.c +                                     // Comando
             teste_while + JUMP +                       // Volta para o início
             define_label(fim_while);                   // Fim do while
           }
         ;

EMPILHA_TS : { ts.push_back( map< string, Simbolo >{} ); } // cria uma nova tabela de símbolos na pilha de tabelas
           ;

/* DESEMPILHA_TS : { ts.pop_back(); } // remove a tabela de símbolos do topo da pilha de tabelas
           ; */

CMD_FUNC : FUNCTION ID { $$ = declara_variavel( Var, $2, $2.linha, $2.coluna ); ts.back()[$2.c[0]].isFunc = true; }
          '(' EMPILHA_TS { ++in_func; alinhamento_return.push_back(0); } LISTA_PARAMs ')' BLOCO_FUNC
          { --in_func;
            alinhamento_return.pop_back(); // Sai do contexto de alinhamento desta função

            string lbl_endereco_funcao = gera_label( "func_" + $2.c[0] );
            string definicao_lbl_endereco_funcao = ":" + lbl_endereco_funcao;

            $$.c = $2.c + "&" + $2.c + "{}"  + "=" + "'&funcao'" +
                  lbl_endereco_funcao + "[=]" + "^";

            // $7 = LISTA_PARAMs, $10 = CMDs (após inserir a mid-rule action)
            funcoes = funcoes + definicao_lbl_endereco_funcao + $7.c + $9.c +
                      "undefined" + "@" + "'&retorno'" + "@"+ "~";
            ts.pop_back();
          } //5+8
          ;

LISTA_PARAMs : PARAMs 
             | EMPILHA_TS { $$.clear(); }
             ;
           
PARAMs : PARAMs ',' PARAM 
         { declara_variavel(Var, $3, $3.linha, $3.coluna); 

          $$.c = $1.c + $3.c + "&" + $3.c + "arguments" + "@" + to_string( $1.contador ) + "[@]" + "=" + "^"; 
          
          if( $3.valor_default.size() > 0 ) {
             string lbl_fim_if = gera_label( "fim_default_if" );
             $$.c += $3.c + "@" + "undefined" + "@" + "==" +
                      "!" + lbl_fim_if + "?" +           
                      $3.c + $3.valor_default + "=" + "^" +
                      define_label( lbl_fim_if );
           }
           $$.contador = $1.contador + 1; }
        /* | PARAMs ',' { $$.c = $1.c; $$.contador = $1.contador; }      */
        | PARAM EMPILHA_TS { // a & a arguments @ 0 [@] = ^ 
            declara_variavel( Var, $1, $1.linha, $1.coluna );
            $$.c = $1.c + "&" + $1.c + "arguments" + "@" + "0" + "[@]" + "=" + "^"; 
                    
            if( $1.valor_default.size() > 0 ) {
                string lbl_fim_if = gera_label( "fim_default_if" );
                string def_lbl_fim_if = define_label( lbl_fim_if );
                $$.c += $1.c + "@" + "undefined" + "@" + "==" +
                          "!" + lbl_fim_if + "?" +       
                          $1.c + $1.valor_default + "=" + "^" +
                          define_label( lbl_fim_if );
            }
            $$.contador = 1; 
          }
        ;
     
PARAM : ID {  $$.c = $1.c;      
        $$.valor_default.clear();
        $$.linha = $1.linha;
        $$.coluna = $1.coluna;
        $$.contador = 1;   
      }
      | ID '=' EOBJ { // Código do IF
        $$.c = $1.c;
        $$.valor_default = $3.c;
        $$.linha = $1.linha;
        $$.coluna = $1.coluna;
        $$.contador = 1; 
        }
      ;

CMD_RETURN : RETURN EOBJ ';'
             { if (alinhamento_return.empty()) { 
                 cerr << "Erro: Não é permitido 'return' fora de funções." << endl; 
                 exit(1); 
               }
               // Apenas: Valor + Endereço + Retorno (o ~ já fecha os escopos)
               $$.c = $2.c + "'&retorno'" + "@" + "~"; 
             }
           | RETURN ';'
             { if (alinhamento_return.empty()) { 
                 cerr << "Erro: Não é permitido 'return' fora de funções." << endl; 
                 exit(1); 
               }
               $$.c = vector<string>{"undefined"} + "@" + "'&retorno'" + "@" + "~"; 
             }  
           ;

LVALUE : ID { checa_simbolo( $1.c[0], false ); $$.c = $1.c; }
       ;

LVALUEPROP : LVALUE '[' EOBJ ']'   { $$.c.clear(); $$.esq = $1.c + "@"; $$.dir = $3.c; }    // b[0]
           | LVALUE '.' ID      { $$.c.clear(); $$.esq = $1.c + "@"; $$.dir = vector<string>{ $3.c[0] }; }   // b.m 
           | LVALUEPROP '[' EOBJ ']' { $$.c.clear(); $$.esq = $1.esq + $1.dir + "[@]"; $$.dir = $3.c; } 
           | LVALUEPROP '.' ID    { $$.c.clear(); $$.esq = $1.esq + $1.dir + "[@]"; $$.dir = vector<string>{ $3.c[0] }; } 
           | F '[' EOBJ ']'          { $$.c.clear(); $$.esq = $1.c; $$.dir = $3.c; }
           | F1 '.' ID            { $$.c.clear(); $$.esq = $1.c; $$.dir = vector<string>{ $3.c[0] }; }
           ;

EOBJ : '{' '}' { $$.c = vector<string>{"{}"}; } // Objeto vazio
     | '{' CAMPOS '}' { $$.c = vector<string>{"{}"} + $2.c; } // Objeto com campos
     | ECOND
     ;

CAMPOS : CAMPO ',' CAMPOS { $$.c = $1.c + $3.c; }
       | CAMPO
       ;

CAMPO : ID ':' EOBJ { $$.c = vector<string>{ $1.c[0] } + $3.c + "[<=]"; }
      | ID { $$.c = vector<string>{ $1.c[0] } + "undefined" + "@" + "[<=]"; }
      ;

ECOND : ECOND '?' EOBJ ':' EOBJ
        { string lbl_else = gera_label("tern_cond");
          string lbl_fim = gera_label("tern_fim");
          $$.c = $1.c +
                  "!" + lbl_else + "?" +     // se falso, vai para else
                  $3.c +                     // então
                  lbl_fim + "#" +            // pula para o fim
                  define_label(lbl_else) +   // else
                  $5.c +                     // senão
                  define_label(lbl_fim);     // fim
        }
      | ATRIB
      ;
      
ATRIB : ID '=' EOBJ { checa_simbolo( $1.c[0], true ); $$.c = $1.c + $3.c + "="; }
      | LVALUEPROP '=' EOBJ { $$.c = $1.esq + $1.dir + $3.c + "[=]"; }
      | LVALUE MAIS_IGUAL EOBJ   { checa_simbolo( $1.c[0], true ); $$.c = $1.c + $1.c + "@" + $3.c + "+" + "="; } // a += e  => a a @ e + =
      | LVALUE MENOS_IGUAL EOBJ  { checa_simbolo( $1.c[0], true ); $$.c = $1.c + $1.c + "@" + $3.c + "-" + "="; } // a -= e  => a a @ e - =
      | LVALUEPROP MAIS_IGUAL EOBJ  {
        string tB = gera_temp("esq"), tI = gera_temp("dir");
        $$.c = vector<string>{
          "<{",
            tB, "&", tB
        } + $1.esq + vector<string>{
            "=", "^",
            tI, "&", tI
        } + $1.dir + vector<string>{
            "=", "^",
            // par para [=]
            tB, "@", tI, "@",
            // par para ler valor atual
            tB, "@", tI, "@", "[@]"
        } + $3.c + vector<string>{
            "+",
            "[=]",
          "}>"
        };
      }
      | LVALUEPROP MENOS_IGUAL EOBJ {
        string tB = gera_temp("esq"), tI = gera_temp("dir");
        $$.c = vector<string>{
          "<{",
            tB, "&", tB
        } + $1.esq + vector<string>{
            "=", "^",
            tI, "&", tI
        } + $1.dir + vector<string>{
            "=", "^",
            // par para [=]
            tB, "@", tI, "@",
            // par para ler valor atual
            tB, "@", tI, "@", "[@]"
        } + $3.c + vector<string>{
            "-",
            "[=]",
          "}>"
        };
      }
     | E

     | ID SETA { 
          ts.push_back( map<string, Simbolo>{} );
          declara_variavel(Var, $1, $1.linha, $1.coluna);
          in_func++;
          alinhamento_return.push_back(0);
          empilha_variavel_capturada();
          escopo_base_lambda.push_back(ts.size() - 1);
        } 
        ATRIB 
        { 
          in_func--;
          alinhamento_return.pop_back();
          set<string> capturas = capturas_atuais();
          desempilha_variavel_capturada();
          escopo_base_lambda.pop_back();
          ts.pop_back();
          
          string lbl_func = gera_label("lambda");
          string def_lbl = ":" + lbl_func;
          
          // Gera objeto função
          $$.c = vector<string>{"{}", "'&funcao'", lbl_func, "[<=]"};
          $$.c += gera_codigo_captura(capturas);
          
          // Lambda com expressão tem return implícito
          funcoes = funcoes + def_lbl 
                  + $1.c + "&" + $1.c + "arguments" + "@" + "0" + "[@]" + "=" + "^"
                  + $4.c + "'&retorno'" + "@" + "~";
        }

     | ID SETA { 
          ts.push_back( map<string, Simbolo>{} );
          declara_variavel(Var, $1, $1.linha, $1.coluna);
          in_func++;
          alinhamento_return.push_back(0);
          empilha_variavel_capturada();
          escopo_base_lambda.push_back(ts.size() - 1);
        } 
        BLOCO_FUNC
        { 
          in_func--;
          alinhamento_return.pop_back();
          set<string> capturas = capturas_atuais();
          desempilha_variavel_capturada();
          escopo_base_lambda.pop_back();
          ts.pop_back();
          
          string lbl_func = gera_label("lambda");
          string def_lbl = ":" + lbl_func;
          
          // Gera objeto função
          $$.c = vector<string>{"{}", "'&funcao'", lbl_func, "[<=]"};
          $$.c += gera_codigo_captura(capturas);
          
          // Lambda com expressão tem return implícito
          funcoes = funcoes + def_lbl 
                  + $1.c + "&" + $1.c + "arguments" + "@" + "0" + "[@]" + "=" + "^"
                  + $4.c + "'&retorno'" + "@" + "~";
        }

     // Lambda com múltiplos parâmetros e expressão: (a, b) => expr
     | '(' LISTA_PARAMs FPL SETA { 
          in_func++;
          alinhamento_return.push_back(0);
          empilha_variavel_capturada();
          escopo_base_lambda.push_back(ts.size() - 1);
        } 
        ATRIB 
        { 
          in_func--;
          alinhamento_return.pop_back();
          set<string> capturas = capturas_atuais();
          desempilha_variavel_capturada();
          escopo_base_lambda.pop_back();
          ts.pop_back(); // LISTA_PARAMs já empilhou
          
          string lbl_func = gera_label("lambda");
          string def_lbl = ":" + lbl_func;
          
          $$.c = vector<string>{"{}", "'&funcao'", lbl_func, "[<=]"};
          $$.c += gera_codigo_captura(capturas);
          
          // Lambda com expressão tem return implícito
          funcoes = funcoes + def_lbl 
                  + $2.c  // código dos parâmetros
                  + $6.c + "'&retorno'" + "@" + "~";
        }

     // Lambda com múltiplos parâmetros e bloco: (a, b) => { ... }
     | '(' LISTA_PARAMs FPL SETA {  
          in_func++;
          alinhamento_return.push_back(0);
          empilha_variavel_capturada();
          escopo_base_lambda.push_back(ts.size() - 1);
        } 
        BLOCO_FUNC
        {
          in_func--;
          alinhamento_return.pop_back();
          set<string> capturas = capturas_atuais();
          desempilha_variavel_capturada();
          escopo_base_lambda.pop_back();
          ts.pop_back();
          
          string lbl_func = gera_label("lambda");
          string def_lbl = ":" + lbl_func;
          
          $$.c = vector<string>{"{}", "'&funcao'", lbl_func, "[<=]"};
          $$.c += gera_codigo_captura(capturas);
          
          funcoes = funcoes + def_lbl 
                  + $2.c  // código dos parâmetros
                  + $6.c  // bloco
                  + "undefined" + "@" + "'&retorno'" + "@" + "~";
        }
     ;
      
// Operadores binários e atribuição
E : LVALUE  { $$.c = $1.c + "@"; } 
  | LVALUEPROP { $$.c = $1.esq + $1.dir + "[@]"; }
  | MAIS_MAIS LVALUE { checa_simbolo( $2.c[0], true ); $$.c = $2.c + $2.c + "@" + "1" + "+" + "="; }
  | MENOS_MENOS LVALUE { checa_simbolo( $2.c[0], true ); $$.c = $2.c + $2.c + "@" + "1" + "-" + "="; }
  | MAIS_MAIS LVALUEPROP
    { string tB = gera_temp("esq"), tI = gera_temp("dir");
      $$.c = vector<string>{
        "<{",
          tB, "&", tB
      } + $2.esq + vector<string>{
          "=", "^",
          tI, "&", tI
      } + $2.dir + vector<string>{
          "=", "^",
          // par para [=]
          tB, "@", tI, "@",
          // novo valor = a[i] + 1
          tB, "@", tI, "@", "[@]", "1", "+",
          "[=]",
        "}>"
      };
    }
  | MENOS_MENOS LVALUEPROP
    { string tB = gera_temp("esq"), tI = gera_temp("dir");
      $$.c = vector<string>{
        "<{",
          tB, "&", tB
      } + $2.esq + vector<string>{
          "=", "^",
          tI, "&", tI
      } + $2.dir + vector<string>{
          "=", "^",
          // par para [=]
          tB, "@", tI, "@",
          // novo valor = a[i] - 1
          tB, "@", tI, "@", "[@]", "1", "-",
          "[=]",
        "}>"
      };
    }
  | E '<' E { $$.c = $1.c + $3.c + "<"; }
  | E '>' E { $$.c = $1.c + $3.c + ">"; }
  | E ME_IG E { $$.c = $1.c + $3.c + "<="; }
  | E MA_IG E { $$.c = $1.c + $3.c + ">="; }
  | E DIF E { $$.c = $1.c + $3.c + "!="; }
  | E IGUAL E { $$.c = $1.c + $3.c + "=="; }
  | E AND E { $$.c = $1.c + $3.c + "&&"; }
  | E OR E { $$.c = $1.c + $3.c + "||"; }
  | E '+' E { $$.c = $1.c + $3.c + "+"; }
  | E '-' E { $$.c = $1.c + $3.c + "-"; }
  | E '*' E { $$.c = $1.c + $3.c + "*"; }
  | E '/' E { $$.c = $1.c + $3.c + "/"; }
  | E '%' E { $$.c = $1.c + $3.c + "%"; }
  | '-' E     { $$.c = "0" + $2.c + "-"; } // unário -
  | '+' E     { $$.c = $2.c; }             // unário +
  | E ASM     { $$.c = $1.c + $2.c; }
  | F

  | FUNCTION '(' LISTA_PARAMs ')' '{' 
    { in_func++;
      alinhamento_return.push_back(0);
      empilha_variavel_capturada();} 
    CMDs '}' 
    { 
      in_func--;
      alinhamento_return.pop_back();
      set<string> capturas = capturas_atuais();
      desempilha_variavel_capturada();
      ts.pop_back();  // LISTA_PARAMs empilhou
      
      string lbl_func = gera_label("anonima");
      string def_lbl = ":" + lbl_func;
      
      // Gera objeto função
      $$.c = vector<string>{"{}", "'&funcao'", lbl_func, "[<=]"};
      $$.c += gera_codigo_captura(capturas);
      
      // Código da função
      funcoes = funcoes + def_lbl 
              + $3.c  // parâmetros
              + $7.c  // corpo
              + "undefined" + "@" + "'&retorno'" + "@" + "~";
    }
   | FUNCTION '(' LISTA_PARAMs ')' '{' 
    { in_func++;
      alinhamento_return.push_back(0); 
      empilha_variavel_capturada(); } 
    '}' 
    { 
      in_func--;
      alinhamento_return.pop_back();
      set<string> capturas = capturas_atuais();
      desempilha_variavel_capturada();
      ts.pop_back();
      
      string lbl_func = gera_label("anonima");
      string def_lbl = ":" + lbl_func;
      
      $$.c = vector<string>{"{}", "'&funcao'", lbl_func, "[<=]"};
      $$.c += gera_codigo_captura(capturas);
      
      funcoes = funcoes + def_lbl 
              + $3.c
              + "undefined" + "@" + "'&retorno'" + "@" + "~";
    }
  ;
  // pode criar uma função com os parametros certos (penultimo) e faz a função com base nela, usa a função para os outros e coloca parametro vazio

F : F1
  | F2
  ;

F1 : CDOUBLE
   | CSTRING
   | TRUE  { $$.c = vector<string>{"true"}; }
   | FALSE { $$.c = vector<string>{"false"}; }
   | '(' EOBJ ')' { $$.c = $2.c; }
   | '[' { empilha_array(""); } ELEMS ']' 
     { desempilha_array();
       $$.c = vector<string>{"[]"} + $3.c; }
   | CHAM
   ;

F2 : CINT
   | LVALUE MAIS_MAIS { checa_simbolo( $1.c[0], true ); $$.c = $1.c + "@" + $1.c + $1.c + "@" + "1" + "+" + "=" + "^"; }
   | LVALUE MENOS_MENOS { checa_simbolo( $1.c[0], true ); $$.c = $1.c + "@" + $1.c + $1.c + "@" + "1" + "-" + "=" + "^"; } 
   | LVALUEPROP MAIS_MAIS 
      { string esq = gera_temp("esq"); 
      string dir = gera_temp("dir");
      
      $$.c = vector<string>{"<{"} 
            + esq + "&" + esq + $1.esq + "=" + "^"
            + dir + "&" + dir + $1.dir + "=" + "^"
            + esq + "@" + dir + "@" + "[@]" 
            + esq + "@" + dir + "@"
            + esq + "@" + dir + "@" + "[@]" 
            + "1" + "+" + "[=]" + "^" + "}>"; 
      }
   | LVALUEPROP MENOS_MENOS 
      { string esq = gera_temp("esq"); 
      string dir = gera_temp("dir");
      
      $$.c = vector<string>{"<{"} 
            + esq + "&" + esq + $1.esq + "=" + "^"
            + dir + "&" + dir + $1.dir + "=" + "^"
            + esq + "@" + dir + "@" + "[@]" 
            + esq + "@" + dir + "@"
            + esq + "@" + dir + "@" + "[@]" 
            + "1" + "-" + "[=]" + "^" + "}>"; 
      }
   ;

ELEMS : ELEM ',' ELEMS { $$.c = $1.c + $3.c; }
      | ELEM 
      ;

ELEM : EOBJ 
       { // Gera: idx valor [<=]
         $$.c = to_string(indice_array_atual()) + $1.c + "[<=]";
         incrementa_indice_array();
       }
     | { // Gera: idx undefined [<=]
         $$.c = vector<string>{ to_string(indice_array_atual()), "undefined", "@", "[<=]" };
         incrementa_indice_array();
       }
     ;

CHAM : CHAM_FUNC '(' LISTA_ARGS ')'  
       { $$.c = $3.c + to_string($3.n_args) + $1.c + "$"; }
     | CHAM '(' LISTA_ARGS ')'  
       { // Permite f(x)(y)(z)
         $$.c = $3.c + to_string($3.n_args) + $1.c + "$"; 
       }
     ;
     
CHAM_FUNC : ID           { checa_simbolo($1.c[0], false); $$.c = $1.c + "@"; }
          | LVALUEPROP   { $$.c = $1.esq + $1.dir + "[@]"; }
          | '(' EOBJ ')' { $$.c = $2.c; }     // (log) retorna o rvalue do log
          ;

LISTA_ARGS : ARGs
          | { $$.clear(); $$.n_args = 0; }
          ;

ARGs : EOBJ ',' ARGs
       { $$.c = $1.c + $3.c;
         $$.n_args = $3.n_args + 1; }
     | EOBJ
       { $$.c = $1.c;
         $$.n_args = 1; }
     /* | { $$.clear();
         $$.n_args = 0; } */
     ;

%%

#include "lex.yy.c"

void yyerror( const char* st ) {
   puts( st ); 
   printf( "Proximo a: %s\n", yytext );
   exit( 0 );
}

int main( int argc, char* argv[] ) {
  yyparse();
  
  return 0;
}