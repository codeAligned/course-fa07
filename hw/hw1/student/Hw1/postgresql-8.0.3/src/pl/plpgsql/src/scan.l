%{
/**********************************************************************
 * scan.l		- Scanner for the PL/pgSQL
 *			  procedural language
 *
 * IDENTIFICATION
 *    $PostgreSQL: pgsql/src/pl/plpgsql/src/scan.l,v 1.38 2004/12/17 03:51:36 neilc Exp $
 *
 *    This software is copyrighted by Jan Wieck - Hamburg.
 *
 *    The author hereby grants permission  to  use,  copy,  modify,
 *    distribute,  and  license this software and its documentation
 *    for any purpose, provided that existing copyright notices are
 *    retained  in  all  copies  and  that  this notice is included
 *    verbatim in any distributions. No written agreement, license,
 *    or  royalty  fee  is required for any of the authorized uses.
 *    Modifications to this software may be  copyrighted  by  their
 *    author  and  need  not  follow  the licensing terms described
 *    here, provided that the new terms are  clearly  indicated  on
 *    the first page of each file where they apply.
 *
 *    IN NO EVENT SHALL THE AUTHOR OR DISTRIBUTORS BE LIABLE TO ANY
 *    PARTY  FOR  DIRECT,   INDIRECT,   SPECIAL,   INCIDENTAL,   OR
 *    CONSEQUENTIAL   DAMAGES  ARISING  OUT  OF  THE  USE  OF  THIS
 *    SOFTWARE, ITS DOCUMENTATION, OR ANY DERIVATIVES THEREOF, EVEN
 *    IF  THE  AUTHOR  HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH
 *    DAMAGE.
 *
 *    THE  AUTHOR  AND  DISTRIBUTORS  SPECIFICALLY   DISCLAIM   ANY
 *    WARRANTIES,  INCLUDING,  BUT  NOT  LIMITED  TO,  THE  IMPLIED
 *    WARRANTIES  OF  MERCHANTABILITY,  FITNESS  FOR  A  PARTICULAR
 *    PURPOSE,  AND NON-INFRINGEMENT.  THIS SOFTWARE IS PROVIDED ON
 *    AN "AS IS" BASIS, AND THE AUTHOR  AND  DISTRIBUTORS  HAVE  NO
 *    OBLIGATION   TO   PROVIDE   MAINTENANCE,   SUPPORT,  UPDATES,
 *    ENHANCEMENTS, OR MODIFICATIONS.
 *
 **********************************************************************/

#include "plpgsql.h"

#include "mb/pg_wchar.h"


/* No reason to constrain amount of data slurped */
#define YY_READ_BUF_SIZE 16777216

/* Avoid exit() on fatal scanner errors (a bit ugly -- see yy_fatal_error) */
#define fprintf(file, fmt, msg)  ereport(ERROR, (errmsg_internal("%s", msg)))

/* Handles to the buffer that the lexer uses internally */
static YY_BUFFER_STATE scanbufhandle;
static char *scanbuf;

static const char *scanstr;		/* original input string */

static int	scanner_functype;
static int	scanner_typereported;
static int	pushback_token;
static bool have_pushback_token;
static int	lookahead_token;	
static bool have_lookahead_token;
static const char *cur_line_start;
static int	cur_line_num;
static char    *dolqstart;      /* current $foo$ quote start string */
static int	dolqlen;			/* signal to plpgsql_get_string_value */

int	plpgsql_SpaceScanned = 0;
%}

%option 8bit
%option never-interactive
%option nodefault
%option nounput
%option noyywrap

%option case-insensitive


%x	IN_STRING
%x	IN_COMMENT
%x	IN_DOLLARQUOTE

digit			[0-9]
ident_start		[A-Za-z\200-\377_]
ident_cont		[A-Za-z\200-\377_0-9\$]

quoted_ident	(\"[^\"]*\")+

identifier		({ident_start}{ident_cont}*|{quoted_ident})

param			\${digit}+

space			[ \t\n\r\f]

/* $foo$ style quotes ("dollar quoting")
 * copied straight from the backend SQL parser
 */
dolq_start		[A-Za-z\200-\377_]
dolq_cont		[A-Za-z\200-\377_0-9]
dolqdelim		\$({dolq_start}{dolq_cont}*)?\$
dolqinside		[^$]+

%%
    /* ----------
     * Local variables in scanner to remember where
     * a string or comment started
     * ----------
     */
    int	start_lineno = 0;
	char *start_charpos = NULL;

    /* ----------
     * Reset the state when entering the scanner
     * ----------
     */
    BEGIN(INITIAL);
    plpgsql_SpaceScanned = 0;

    /* ----------
     * On the first call to a new source report the
     * function's type (T_FUNCTION or T_TRIGGER)
     * ----------
     */
	if (!scanner_typereported)
	{
		scanner_typereported = 1;
		return scanner_functype;
	}

    /* ----------
     * The keyword rules
     * ----------
     */
:=				{ return K_ASSIGN;			}
=				{ return K_ASSIGN;			}
\.\.			{ return K_DOTDOT;			}
alias			{ return K_ALIAS;			}
begin			{ return K_BEGIN;			}
close			{ return K_CLOSE;			}
constant		{ return K_CONSTANT;		}
cursor			{ return K_CURSOR;			}
debug			{ return K_DEBUG;			}
declare			{ return K_DECLARE;			}
default			{ return K_DEFAULT;			}
diagnostics		{ return K_DIAGNOSTICS;		}
else			{ return K_ELSE;			}
elseif          { return K_ELSIF;           }
elsif           { return K_ELSIF;           }
end				{ return K_END;				}
exception		{ return K_EXCEPTION;		}
execute			{ return K_EXECUTE;			}
exit			{ return K_EXIT;			}
fetch			{ return K_FETCH;			}
for				{ return K_FOR;				}
from			{ return K_FROM;			}
get				{ return K_GET;				}
if				{ return K_IF;				}
in				{ return K_IN;				}
info			{ return K_INFO;			}
into			{ return K_INTO;			}
is				{ return K_IS;				}
log				{ return K_LOG;				}
loop			{ return K_LOOP;			}
next			{ return K_NEXT;			}
not				{ return K_NOT;				}
notice			{ return K_NOTICE;			}
null			{ return K_NULL;			}
open			{ return K_OPEN;			}
or				{ return K_OR;				}
perform			{ return K_PERFORM;			}
raise			{ return K_RAISE;			}
rename			{ return K_RENAME;			}
result_oid		{ return K_RESULT_OID;		}
return			{ return K_RETURN;			}
reverse			{ return K_REVERSE;			}
row_count		{ return K_ROW_COUNT;		}
select			{ return K_SELECT;			}
then			{ return K_THEN;			}
to				{ return K_TO;				}
type			{ return K_TYPE;			}
warning			{ return K_WARNING;			}
when			{ return K_WHEN;			}
while			{ return K_WHILE;			}

^#option		{ return O_OPTION;			}
dump			{ return O_DUMP;			}


    /* ----------
     * Special word rules
	 *
	 * We set plpgsql_error_lineno in each rule so that errors reported
	 * in the pl_comp.c subroutines will point to the right place.
     * ----------
     */
{identifier}					{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_word(yytext); }
{identifier}{space}*\.{space}*{identifier}	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_dblword(yytext); }
{identifier}{space}*\.{space}*{identifier}{space}*\.{space}*{identifier}	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_tripword(yytext); }
{identifier}{space}*%TYPE		{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_wordtype(yytext); }
{identifier}{space}*\.{space}*{identifier}{space}*%TYPE	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_dblwordtype(yytext); }
{identifier}{space}*\.{space}*{identifier}{space}*\.{space}*{identifier}{space}*%TYPE	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_tripwordtype(yytext); }
{identifier}{space}*%ROWTYPE	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_wordrowtype(yytext); }
{identifier}{space}*\.{space}*{identifier}{space}*%ROWTYPE	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_dblwordrowtype(yytext); }
{param}							{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_word(yytext); }
{param}{space}*\.{space}*{identifier}	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_dblword(yytext); }
{param}{space}*\.{space}*{identifier}{space}*\.{space}*{identifier}	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_tripword(yytext); }
{param}{space}*%TYPE			{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_wordtype(yytext); }
{param}{space}*\.{space}*{identifier}{space}*%TYPE	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_dblwordtype(yytext); }
{param}{space}*\.{space}*{identifier}{space}*\.{space}*{identifier}{space}*%TYPE	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_tripwordtype(yytext); }
{param}{space}*%ROWTYPE		{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_wordrowtype(yytext); }
{param}{space}*\.{space}*{identifier}{space}*%ROWTYPE	{
	plpgsql_error_lineno = plpgsql_scanner_lineno();
	return plpgsql_parse_dblwordrowtype(yytext); }

{digit}+		{ return T_NUMBER;			}

\".				{
				plpgsql_error_lineno = plpgsql_scanner_lineno();
				ereport(ERROR,
						(errcode(ERRCODE_DATATYPE_MISMATCH),
						 errmsg("unterminated quoted identifier")));
			}

    /* ----------
     * Ignore whitespaces but remember this happened
     * ----------
     */
{space}+		{ plpgsql_SpaceScanned = 1;		}

    /* ----------
     * Eat up comments
     * ----------
     */
--[^\r\n]*		;

\/\*			{ start_lineno = plpgsql_scanner_lineno();
			  BEGIN(IN_COMMENT);
			}
<IN_COMMENT>\*\/	{ BEGIN(INITIAL); plpgsql_SpaceScanned = 1; }
<IN_COMMENT>\n		;
<IN_COMMENT>.		;
<IN_COMMENT><<EOF>>	{
				plpgsql_error_lineno = start_lineno;
				ereport(ERROR,
						(errcode(ERRCODE_DATATYPE_MISMATCH),
						 errmsg("unterminated comment")));
			}

    /* ----------
     * Collect anything inside of ''s and return one STRING token
	 *
	 * Hacking yytext/yyleng here lets us avoid using yymore(), which is
	 * a win for performance.  It's safe because we know the underlying
	 * input buffer is not changing.
     * ----------
     */
'			{
			  start_lineno = plpgsql_scanner_lineno();
			  start_charpos = yytext;
			  BEGIN(IN_STRING);
			}
<IN_STRING>\\.		{ }
<IN_STRING>\\		{ /* can only happen with \ at EOF */ }
<IN_STRING>''		{ }
<IN_STRING>'		{
			  /* tell plpgsql_get_string_value it's not a dollar quote */
			  dolqlen = 0;
			  /* adjust yytext/yyleng to describe whole string token */
			  yyleng += (yytext - start_charpos);
			  yytext = start_charpos;
			  BEGIN(INITIAL);
			  return T_STRING;
			}
<IN_STRING>[^'\\]+	{ }
<IN_STRING><<EOF>>	{
				plpgsql_error_lineno = start_lineno;
				ereport(ERROR,
						(errcode(ERRCODE_DATATYPE_MISMATCH),
						 errmsg("unterminated string")));
			}

{dolqdelim}		{
			  start_lineno = plpgsql_scanner_lineno();
			  start_charpos = yytext;
			  dolqstart = pstrdup(yytext);
			  BEGIN(IN_DOLLARQUOTE);
			}
<IN_DOLLARQUOTE>{dolqdelim} {
			  if (strcmp(yytext, dolqstart) == 0)
			  {
					pfree(dolqstart);
					/* tell plpgsql_get_string_value it is a dollar quote */
					dolqlen = yyleng;
					/* adjust yytext/yyleng to describe whole string token */
					yyleng += (yytext - start_charpos);
					yytext = start_charpos;
					BEGIN(INITIAL);
					return T_STRING;
			  }
			  else
			  {
					/*
					 * When we fail to match $...$ to dolqstart, transfer
					 * the $... part to the output, but put back the final
					 * $ for rescanning.  Consider $delim$...$junk$delim$
					 */
					yyless(yyleng-1);
			  }
			}
<IN_DOLLARQUOTE>{dolqinside} { }
<IN_DOLLARQUOTE>.	{ /* needed for $ inside the quoted text */ }
<IN_DOLLARQUOTE><<EOF>>	{ 
				plpgsql_error_lineno = start_lineno;
				ereport(ERROR,
						(errcode(ERRCODE_DATATYPE_MISMATCH),
						 errmsg("unterminated dollar-quoted string")));
			}

    /* ----------
     * Any unmatched character is returned as is
     * ----------
     */
.			{ return yytext[0];			}

%%


/*
 * This is the yylex routine called from outside. It exists to provide
 * a pushback facility, as well as to allow us to parse syntax that
 * requires more than one token of lookahead.
 */
int
plpgsql_yylex(void)
{
	int cur_token;

	if (have_pushback_token)
	{
		have_pushback_token = false;
		cur_token = pushback_token;
	}
	else if (have_lookahead_token)
	{
		have_lookahead_token = false;
		cur_token = lookahead_token;
	}
	else
		cur_token = yylex();

	/* Do we need to look ahead for a possible multiword token? */
	switch (cur_token)
	{
		/* RETURN NEXT must be reduced to a single token */
		case K_RETURN:
			if (!have_lookahead_token)
			{
				lookahead_token = yylex();
				have_lookahead_token = true;
			}
			if (lookahead_token == K_NEXT)
			{
				have_lookahead_token = false;
				cur_token = K_RETURN_NEXT;
			}
			break;

		default:
			break;
	}

	return cur_token;
}

/*
 * Push back a single token to be re-read by next plpgsql_yylex() call.
 */
void
plpgsql_push_back_token(int token)
{
	if (have_pushback_token)
		elog(ERROR, "cannot push back multiple tokens");
	pushback_token = token;
	have_pushback_token = true;
}

/*
 * Report a syntax error.
 */
void
plpgsql_yyerror(const char *message)
{
	const char *loc = yytext;
	int			cursorpos;

	plpgsql_error_lineno = plpgsql_scanner_lineno();

	/* in multibyte encodings, return index in characters not bytes */
	cursorpos = pg_mbstrlen_with_len(scanbuf, loc - scanbuf) + 1;

	if (*loc == YY_END_OF_BUFFER_CHAR)
	{
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 /* translator: %s is typically "syntax error" */
				 errmsg("%s at end of input", message),
				 internalerrposition(cursorpos),
				 internalerrquery(scanstr)));
	}
	else
	{
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 /* translator: first %s is typically "syntax error" */
				 errmsg("%s at or near \"%s\"", message, loc),
				 internalerrposition(cursorpos),
				 internalerrquery(scanstr)));
	}
}

/*
 * Get the line number at which the current token ends.  This substitutes
 * for flex's very poorly implemented yylineno facility.
 *
 * We assume that flex has written a '\0' over the character following the
 * current token in scanbuf.  So, we just have to count the '\n' characters
 * before that.  We optimize this a little by keeping track of the last
 * '\n' seen so far.
 */
int
plpgsql_scanner_lineno(void)
{
	const char *c;

	while ((c = strchr(cur_line_start, '\n')) != NULL)
	{
		cur_line_start = c + 1;
		cur_line_num++;
	}
	return cur_line_num;
}

/*
 * Called before any actual parsing is done
 *
 * Note: the passed "str" must remain valid until plpgsql_scanner_finish().
 * Although it is not fed directly to flex, we need the original string
 * to cite in error messages.
 */
void
plpgsql_scanner_init(const char *str, int functype)
{
	Size	slen;

	slen = strlen(str);

	/*
	 * Might be left over after ereport()
	 */
	if (YY_CURRENT_BUFFER)
		yy_delete_buffer(YY_CURRENT_BUFFER);

	/*
	 * Make a scan buffer with special termination needed by flex.
	 */
	scanbuf = palloc(slen + 2);
	memcpy(scanbuf, str, slen);
	scanbuf[slen] = scanbuf[slen + 1] = YY_END_OF_BUFFER_CHAR;
	scanbufhandle = yy_scan_buffer(scanbuf, slen + 2);

	/* Other setup */
	scanstr = str;

    scanner_functype = functype;
    scanner_typereported = 0;

	have_pushback_token = false;
	have_lookahead_token = false;

	cur_line_start = scanbuf;
	cur_line_num = 1;

	/*----------
	 * Hack: skip any initial newline, so that in the common coding layout
	 *		CREATE FUNCTION ... AS '
	 *			code body
	 *		' LANGUAGE 'plpgsql';
	 * we will think "line 1" is what the programmer thinks of as line 1.
	 *----------
	 */
    if (*cur_line_start == '\r')
        cur_line_start++;
    if (*cur_line_start == '\n')
        cur_line_start++;

	BEGIN(INITIAL);
}

/*
 * Called after parsing is done to clean up after plpgsql_scanner_init()
 */
void
plpgsql_scanner_finish(void)
{
	yy_delete_buffer(scanbufhandle);
	pfree(scanbuf);
}

/*
 * Called after a T_STRING token is read to get the string literal's value
 * as a malloc'd string.  (We make this a separate call because in many
 * scenarios there's no need to get the decoded value.)
 *
 * Note: we expect the literal to be the most recently lexed token.  This
 * would not work well if we supported multiple-token pushback or if 
 * plpgsql_yylex() wanted to read ahead beyond a T_STRING token.
 */
char *
plpgsql_get_string_value(void)
{
	char	   *result;
	const char *cp;
	int			len;

	if (dolqlen > 0)
	{
		/* Token is a $foo$...$foo$ string */
		len = yyleng - 2 * dolqlen;
		Assert(len >= 0);
		result = (char *) malloc(len + 1);
		memcpy(result, yytext + dolqlen, len);
		result[len] = '\0';
	}
	else
	{
		/* Token is a '...' string */
		result = (char *) malloc(yyleng + 1);	/* more than enough room */
		len = 0;
		for (cp = yytext; *cp; cp++)
		{
			if (*cp == '\'')
			{
				if (cp[1] == '\'')
					result[len++] = *cp++;
				/* else it must be string start or end quote */
			}
			else if (*cp == '\\')
			{
				if (cp[1] != '\0')	/* just a paranoid check */
					result[len++] = *(++cp);
			}
			else
				result[len++] = *cp;
		}
		result[len] = '\0';
	}
	return result;
}
