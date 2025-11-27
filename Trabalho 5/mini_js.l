%{

int token( int tk );

// Função trim: Remove um conjunto de caracteres do início e fim de uma string.
string trim( const string& str, const string& chars_to_remove ) {
    size_t start = str.find_first_not_of( chars_to_remove );
    if ( string::npos == start ) {
        return ""; // A string só tinha os caracteres a remover
    }
    size_t end = str.find_last_not_of( chars_to_remove );
    return str.substr( start, end - start + 1 );
}

// Função tokeniza: Divide uma string em um vetor de strings usando espaço como delimitador.
vector<string> tokeniza( const string& str ) {
    vector<string> tokens;
    string token;
    istringstream tokenStream( str ); // Usar stringstream para tokenização
    
    // Lê do stream até encontrar um espaço
    while ( getline( tokenStream, token, ' ' ) ) {
        // Remove espaços em branco no início/fim de cada token (se houver)
        string trimmed_token = trim(token, " \t\n\r"); 
        if ( !trimmed_token.empty() ) {
            tokens.push_back( trimmed_token );
        }
    }
    return tokens;
}

%}

D  	        [0-9]
L   	    [A-Za-z_]
INT	        {D}+
DOUBLE      {D}+"."{D}+([Ee][+\-]?{D}+)?
ID          {L}({L}|{D})*
STRING      (\"(\\\"|\"\"|[^"])*\")|\'(\\\'|\'\'|[^'])*\'

%%

"\t"       { coluna += 4; }
" "        { coluna++; }
"\n"       { linha++; coluna = 1; }
"\r"       { linha++; coluna = 1; }

{DOUBLE}   { return token( CDOUBLE ); }
{INT}      { return token( CINT ); }
{STRING}   { return token( CSTRING ); }

"&&"      { return token( AND ); }
"||"      { return token( OR ); }
"<="      { return token( ME_IG ); }
">="      { return token( MA_IG ); }
"!="      { return token( DIF ); }
"=="      { return token( IGUAL ); }

"true"    { return TRUE; }
"false"   { return FALSE; }

"+="       { return token( MAIS_IGUAL ); }
"++"       { return token( MAIS_MAIS ); }
"-="       { return token( MENOS_IGUAL ); }
"--"       { return token( MENOS_MENOS ); }

"=>"                            { return token( SETA ); }
")"/[ \n\t\r]*"=>"              { return token( FPL ); }
","[ \n\t\r]*")"/[ \n\t\r]*"=>" { return token( FPL ); }
","/[ \n\t\r]*")"               { return token( ')' ); }
"("[ \n\t\r]*","[ \n\t\r]*")"   { return token( 1 ); /* ERRO */ }

"let"      { return token( LET ); }
"const"    { return token( CONST ); }
"var"      { return token( VAR ); }

"if"       { return token( IF ); }
"else"     { return token( ELSE ); }
"for"      { return token( FOR ); }
"while"    { return token( WHILE ); }

"function" { return token( FUNCTION ); }
"return"   { return token( RETURN ); }  

"asm{".*"}"  {  string lexema = trim( yytext + 3, "{}" ); 
                yylval.c = tokeniza( lexema );
                coluna += strlen( yytext ); 
                return ASM; }

{ID}       { return token( ID ); }

.          { return token( *yytext ); }

%%

int token( int tk ) {  
  yylval.c = vector<string>{ yytext };
  coluna += strlen( yytext ); 
  
  yylval.linha = linha;
  yylval.coluna = coluna;

  return tk;
}