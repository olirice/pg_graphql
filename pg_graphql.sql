/*
******************************
** File: setup.sql
** Name: Oliver Rice
** Date: 2019-12-11
** Desc: Setup for gql SQL schema
******************************

*/

drop schema if exists gql cascade;

create schema gql;


/*
******************************
** File: utils.sql
** Name: Oliver Rice
** Date: 2019-12-11
** Desc: Utilities
******************************
*/


create or replace function gql.format_sql(text)
returns text as
$$
   DECLARE
      v_ugly_string       ALIAS FOR $1;
      v_beauty            text;
      v_tmp_name          text;
   BEGIN
      -- let us create a unique view name
      v_tmp_name := 'temp_' || md5(v_ugly_string);
      EXECUTE 'CREATE TEMPORARY VIEW ' ||
      v_tmp_name || ' AS ' || v_ugly_string;

      -- the magic happens here
      SELECT pg_get_viewdef(v_tmp_name) INTO v_beauty;

      -- cleanup the temporary object
      EXECUTE 'DROP VIEW ' || v_tmp_name;
      RETURN v_beauty;
   EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'you have provided an invalid string: % / %',
            sqlstate, sqlerrm;
   END;
$$ language 'plpgsql';


/*
	Table Info
*/
create or replace function gql.to_primary_key_cols(_table_schema text, _table_name text) returns text[] as $$
	select
		array_agg(column_name)::text[]
	from (
		select
			c.table_schema,
			c.table_name,
			c.column_name
		from
			information_schema.table_constraints tc
			join information_schema.constraint_column_usage AS ccu USING (constraint_schema, constraint_name)
			join information_schema.columns AS c ON c.table_schema = tc.constraint_schema
  			and tc.table_name = c.table_name and ccu.column_name = c.column_name
			where constraint_type = 'PRIMARY KEY'
	) constr
	where
		constr.table_schema = _table_schema
		and constr.table_name = _table_name
$$ language sql stable returns null on null input;


create or replace view gql.table_info as
    select tab.table_schema::text,
        tab.table_name::text,
        gql.to_primary_key_cols(tab.table_schema, tab.table_name) pkey_cols
    from information_schema.tables tab
    where tab.table_schema not in ('pg_catalog','information_schema','gql')
    group by tab.table_schema,
        tab.table_name,
        tab.table_type;

/*
	Column Info
*/
create or replace view gql.column_info as
    select
        table_schema::text,
        table_name::text,
        column_name::text,
        is_nullable='NO' as not_null,
        data_type::text sql_data_type,
        column_name::text = any(pk.pk_cols) is_pkey,
        ordinal_position
    from
        information_schema.columns,
        lateral gql.to_primary_key_cols(table_schema::text, table_name::text) pk(pk_cols)
    where
        table_schema not in ('pg_catalog','information_schema','gql')
    order by
        table_name,
        ordinal_position;

create type gql.cardinality as enum ('ONE', 'MANY');

create or replace view gql.relationship_info as
    with constraint_cols as (
        select
            table_schema::text,
            table_name::text,
            constraint_name::text,
            array_agg(column_name::text) column_names
        from information_schema.constraint_column_usage
        group by table_schema,
            table_name,
            constraint_name
    ),
	directional as (
        select 
            tc.constraint_name::text,
            tc.table_schema::text,
            tc.table_name::text local_table,
            array_agg(kcu.column_name) local_columns,
            'MANY'::gql.cardinality as local_cardinality,
            ccu.table_name::text as foreign_table,
            ccu.column_names::text[] as foreign_columns,
            'ONE'::gql.cardinality as foreign_cardinality
        from
            information_schema.table_constraints as tc
        join
            information_schema.key_column_usage as kcu
            on tc.constraint_name = kcu.constraint_name
            and tc.table_schema = kcu.table_schema
        join constraint_cols as ccu
            on ccu.constraint_name = tc.constraint_name
            and ccu.table_schema = tc.table_schema
        where
            tc.constraint_type = 'FOREIGN KEY'
        group by
            tc.constraint_name,
            tc.table_schema,
            tc.table_name,
            ccu.table_schema,
            ccu.table_name,
            ccu.column_names
    )
    select *
    from
        directional
    union all
    select
        'reverse_' || constraint_name,
	    table_schema,
	    foreign_table as local_table,
	    foreign_columns as local_columns,
        foreign_cardinality as local_cardinality,
	    local_table as foreign_table,
	    local_columns as foreign_columns,
        local_cardinality as foreign_cardinality
    from
        directional;



create or replace function gql.list_tables(_table_schema text) returns text[] as
$$ select array_agg(table_name) from gql.table_info ti where ti.table_schema = _table_schema;
$$ language sql strict;

create or replace function gql.list_columns(_table_schema text, _table_name text) returns text[] as
$$  select
		array_agg(column_name)
	from
		gql.column_info ti
	where
		ti.table_schema = _table_schema
		and ti.table_name = _table_name;
$$ language sql strict;

create or replace function gql.list_relationships(_table_schema text, _table_name text) returns text[] as
$$  select
		array_agg(constraint_name)
	from
		gql.relationship_info ti
	where
		ti.table_schema = _table_schema
		and ti.local_table = _table_name;
$$ language sql strict;

create or replace function gql.get_column_sql_type(_table_schema text, _table_name text, _column_name text) returns text as
$$  select
		sql_data_type
	from
		gql.column_info ti
	where
		ti.table_schema = _table_schema
		and ti.table_name = _table_name
		and ti.column_name = _column_name;
$$ language sql strict;




create or replace function gql.pascal_case(entity_name text) returns text as $$
	SELECT replace(initcap(replace(entity_name, '_', ' ')), ' ', '')
$$ language sql immutable returns null on null input;


create or replace function gql.camel_case(entity_name text) returns text as $$
	select lower(substring(pascal_name,1,1)) || substring(pascal_name,2)
	from
		(select gql.pascal_case(entity_name) as pascal_name) pn
$$ language sql immutable returns null on null input;



/*
******************************
** File: schema.sql
** Name: Oliver Rice
** Date: 2019-12-11
** Desc: Parse a token array into an abstract syntax tree (AST)
******************************

Public API:
    - gql.get_schema(schema_name text) returns jsonb

Usage:
    select gql.get_schema('public')
*/

/*
	GRAPHQL Type Names
*/


-- base
-- edge
-- connection
-- condition
-- input
-- patch
-- entrypoint one
-- entrypoint connection


create or replace function gql.to_base_name(_table_name text) returns text as
$$ select gql.pascal_case(_table_name)
$$ language sql immutable returns null on null input;

create or replace function gql.to_condition_name(_table_name text) returns text as
$$ select gql.pascal_case(_table_name || '_condition')
$$ language sql immutable returns null on null input;


create or replace function gql.to_edge_name(_table_name text) returns text as
$$ select gql.pascal_case(_table_name || '_edge')
$$ language sql immutable returns null on null input;

create or replace function gql.to_connection_name(_table_name text) returns text as
$$ select gql.pascal_case(_table_name || '_connection')
$$ language sql immutable returns null on null input;

create or replace function gql.to_entrypoint_one_name(_table_name text) returns text as
$$ select gql.camel_case(_table_name)
$$ language sql immutable returns null on null input;

create or replace function gql.to_entrypoint_connection_name(_table_name text) returns text as
$$ select gql.camel_case('all_' || _table_name)
$$ language sql immutable returns null on null input;

create or replace function gql.to_field_name(_column_name text) returns text as
$$ select _column_name
$$ language sql immutable returns null on null input;


create or replace function gql.to_gql_type(sql_type text, not_null bool) returns text as
$$ select
		case
			when sql_type in ('integer', 'int4', 'smallint', 'serial') then 'Int'
			when sql_type ilike 'date' then 'Datetime'
			when sql_type ilike 'time%' then 'Datetime'
			else 'String'
		end || case
			when not_null then '!' else '' end;
$$ language sql immutable strict;


create or replace function gql.to_gql_type(_table_schema text, _table_name text, _column_name text) returns text as $$
	/* Assign a concrete graphql data type (non-connection) from a sql datatype e.g. 'int4' -> 'Integer!' */
	select 
        gql.to_gql_type(sql_type := sql_data_type, not_null := not_null)
	from
		gql.column_info fm
	where
		fm.table_schema = _table_schema
		and fm.table_name = _table_name
		and fm.column_name = _column_name
$$ language sql stable returns null on null input;


create or replace function gql.relationship_to_gql_field_name(_constraint_name text) returns text
	language plpgsql as
$$
declare
	field_name text := null;
	rec record := null;
begin
	select *
	from gql.relationship_info ri
	where ri.constraint_name = _constraint_name
	limit 1
	into rec;
	
	field_name := rec.foreign_table;
	field_name := field_name || (select case
		when rec.foreign_cardinality = 'MANY' then '_collection_by_'
		when rec.foreign_cardinality = 'ONE' then '_by_'
		else '_UNREACHABLE_'
	end);

	field_name := field_name || array_to_string(rec.local_columns, '_and_');
	field_name := field_name || '_to_';
	field_name := field_name || array_to_string(rec.foreign_columns, '_and_');	
	return field_name;
end;
$$;


create or replace function gql.to_connection_args(_table_name text) returns text
    language sql as
$$ select format('(first: Int after: Cursor last: Int before: Cursor, condition: %s)', gql.to_condition_name(_table_name));
$$;

create or replace function gql.relationship_to_gql_field_def(_constraint_name text) returns text
	language plpgsql as
$$
declare
	field_name text := null;
	rec record := null;
begin
	select *
	from gql.relationship_info ri
	where ri.constraint_name = _constraint_name
	limit 1
	into rec;
	
	field_name := gql.relationship_to_gql_field_name(_constraint_name);

    if rec.foreign_cardinality = 'MANY' then
        field_name := field_name || gql.to_connection_args(rec.foreign_table);
    end if;
	return field_name;
end;
$$;



create or replace function gql.relationship_to_gql_type(_constraint_name text) returns text
	language plpgsql as
$$
declare
	data_type text := null;
	rec record := null;
	foreign_base_type_name text := null;
begin
	select *
	from gql.relationship_info ri
	where ri.constraint_name = _constraint_name
	limit 1
	into rec;
	foreign_base_type_name := gql.to_base_name(rec.foreign_table);
	return (select case
		when rec.foreign_cardinality = 'MANY' then gql.to_connection_name(rec.foreign_table) || '!'
		when rec.foreign_cardinality = 'ONE' then foreign_base_type_name || '!'
		else 'UNREACHABLE'
	end);
end;
$$;



create or replace function gql.to_base_type(_table_schema text, _table_name text) returns text
	language plpgsql as
$$
declare
	base_type_name text := gql.to_base_name(_table_name);
	column_arr text[] := gql.list_columns(_table_schema, _table_name);
	col_name text := null;
    col_field_name text;
	col_gql_type text := null;
	res text := 'type ' || base_type_name || e' {\n\tnodeId: ID!\n';
	relation_arr text[] := gql.list_relationships(_table_schema, _table_name);
	relation_name text := null;
	relation_field_def text := null;
	relation_gql_type text := null;
begin
	for col_name in select unnest(column_arr) loop
        col_field_name := gql.to_field_name(col_name);
		col_gql_type := gql.to_gql_type(_table_schema, _table_name, col_name);
		-- Add column to result type
		res := res || e'\t' || col_field_name || ': ' || col_gql_type || e'\n';
	end loop;
	
	for relation_name in select unnest(relation_arr) loop
		 relation_field_def := gql.relationship_to_gql_field_def(relation_name);
		 relation_gql_type := gql.relationship_to_gql_type(relation_name);
		 
		 res := res || e'\t' || relation_field_def || ': ' || relation_gql_type || e'\n';
	end loop;
	res := res || '}';	
	return res;
end;
$$;

create or replace function gql.strip_not_null(gql_type text) returns text as
$$ select replace(gql_type, '!', ''); $$ language sql;

create or replace function gql.to_condition_type(_table_schema text, _table_name text) returns text
	language plpgsql as
$$
declare
	condition_type_name text := gql.to_condition_name(_table_name);
	column_arr text[] := gql.list_columns(_table_schema, _table_name);
	col_name text := null;
    col_field_name text;
	col_gql_type text := null;
	res text := 'input ' || condition_type_name || e' {\n\tnodeId: ID\n';
begin
	for col_name in select unnest(column_arr) loop
        col_field_name := gql.to_field_name(col_name);
		col_gql_type := gql.strip_not_null(gql.to_gql_type(_table_schema, _table_name, col_name));
		-- Add column to result type
		res := res || e'\t' || col_field_name || ': ' || col_gql_type || e'\n';
	end loop;
	res := res || '}';	
	return res;
end;
$$;




create or replace function gql.to_edge_type(_table_schema text, _table_name text) returns text
	language plpgsql as
$$
declare
	base_type_name text := gql.to_base_name(_table_name);
	edge_type_name text := gql.to_edge_name(_table_name);
begin
    return format($typedef$
type %s {
    cursor: Cursor
    node: %s
}    
$typedef$, edge_type_name, base_type_name);
end;
$$;

create or replace function gql.to_connection_type(_table_schema text, _table_name text) returns text
	language plpgsql as
$$
declare
	edge_type_name text := gql.to_edge_name(_table_name);
	connection_type_name text := gql.to_connection_name(_table_name);
    -- TODO
	page_info text := null;
begin
    return format($typedef$
type %s {
    edges: [%s!]!
    total_count: Int!
    pageInfo: PageInfo!
}    
$typedef$, connection_type_name, edge_type_name);
end;
$$;


create or replace function gql.to_entrypoint_one(_table_schema text, _table_name text) returns text as $$
	select
        format('%s(nodeId: ID!): %s',
            gql.to_entrypoint_one_name(_table_name),
            gql.to_base_name(_table_name)
        );
$$ language sql stable returns null on null input;


create or replace function gql.to_entrypoint_connection(_table_schema text, _table_name text) returns text as $$
	select
        format('%s%s: %s',
            gql.to_entrypoint_connection_name(_table_name),
            gql.to_connection_args(_table_name),
            gql.to_connection_name(_table_name)
        );
$$ language sql stable returns null on null input;


create or replace function gql.to_query(_table_schema text) returns text
 language plpgsql as $$
declare
    entrypoint_one_clause text := '';
    entrypoint_connection_clause text := '';
    tab_rec record;
begin

    for tab_rec in (select * from gql.table_info ti where ti.table_schema = _table_schema) loop
        entrypoint_one_clause := concat(
            entrypoint_one_clause,
            '    ',
            gql.to_entrypoint_one(
                tab_rec.table_schema,
                tab_rec.table_name
            ),
            e'\n');
        entrypoint_connection_clause := concat(
            entrypoint_connection_clause,
            '    ',
            gql.to_entrypoint_connection(
                tab_rec.table_schema,
                tab_rec.table_name
            ),
            e'\n');
    end loop;

	return format('
type Query{
%s
%s
}', entrypoint_one_clause, entrypoint_connection_clause);
end;
$$;


create or replace function gql.to_schema(_table_schema text) returns text as $$
    
	select '
scalar Cursor

"""
ISO 8601: https://en.wikipedia.org/wiki/ISO_8601
"""
scalar Datetime

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: Cursor
  endCursor: Cursor
}
' ||
        string_agg(zzz.def, E'\n')
	from
		(
			select gql.to_base_type(table_schema, table_name) def from gql.table_info where table_schema = _table_schema
			union all
			select gql.to_edge_type(table_schema, table_name) def from gql.table_info where table_schema = _table_schema
			union all
			select gql.to_connection_type(table_schema, table_name) def from gql.table_info where table_schema = _table_schema
			union all
			select gql.to_condition_type(table_schema, table_name) def from gql.table_info where table_schema = _table_schema
			union all
			select gql.to_query(_table_schema)
		 ) zzz
$$ language sql stable returns null on null input;


/*
******************************
** File: tokenizer.sql
** Name: Oliver Rice
** Date: 2019-12-11
** Desc: Tokenize a graphql query operation
******************************


select
    gql.tokenize_operation('
        query {
            account(id: 1, name: "Oliver") {
                # accounts have comments!
                id
                name
                createdAt
            }
        }'
    )
*/

create type gql.token_kind as enum (
	'BANG', 'DOLLAR', 'AMP', 'PAREN_L', 'PAREN_R',
	'COLON', 'EQUALS', 'AT', 'BRACKET_L', 'BRACKET_R',
	'COMMA','BRACE_L', 'BRACE_R', 'PIPE', 'SPREAD',
	'NAME', 'INT', 'FLOAT', 'STRING', 'BLOCK_STRING',
	'COMMENT', 'WHITESPACE', 'ERROR'
);

create type gql.token as (
	kind gql.token_kind,
	content text
);


create or replace function gql.tokenize_operation(payload text) returns gql.token[]
    language plpgsql immutable strict parallel safe
as $BODY$
    declare
        tokens gql.token[] := Array[]::gql.token[];
        cur_token gql.token;
        first_char char := null;
        maybe_tok text;
    begin
        loop
            exit when payload = '';
           
            maybe_tok = substring(payload from '^\s+');
            if maybe_tok is not null then
                payload := substring(payload, character_length(maybe_tok)+1, 99999);
                continue;
            end if;

            maybe_tok = substring(payload from '^[_A-Za-z][_0-9A-Za-z]*');
            if maybe_tok is not null then
                payload := substring(payload, character_length(maybe_tok)+1, 99999);
                tokens := tokens || ('NAME', maybe_tok)::gql.token;
                continue;
            end if;

            first_char := substring(payload, 1, 1);
            
            if first_char = '{' then
                payload := substring(payload, 2, 99999);
                tokens := tokens || ('BRACE_L', '{')::gql.token;
                continue;
            end if;

            if first_char = '}' then
                payload := substring(payload, 2, 99999);
                tokens := tokens || ('BRACE_R', '}')::gql.token;
                continue;
            end if;

            if first_char = '(' then
                payload := substring(payload, 2, 99999);
                tokens := tokens || ('PAREN_L', '(')::gql.token;
                continue;
            end if;

            if first_char = ')' then
                payload := substring(payload, 2, 99999);
                tokens := tokens || ('PAREN_R', ')')::gql.token;
                continue;
            end if;

            if first_char = ':' then
                payload := substring(payload, 2, 99999);
                tokens := tokens || ('COLON', ':')::gql.token;
                continue;
            end if;

            maybe_tok = substring(payload from '^"""(.*?)"""');
            if maybe_tok is not null then
                payload := substring(payload, character_length(maybe_tok)+7, 99999);
                tokens := tokens || ('BLOCK_STRING', maybe_tok)::gql.token;
                continue;
            end if;

            maybe_tok = substring(payload from '^"(.*?)"');
            if maybe_tok is not null then
                payload := substring(payload, character_length(maybe_tok)+3, 99999);
                tokens := tokens || ('STRING', maybe_tok)::gql.token;
                continue;
            end if;

            maybe_tok = substring(payload from '^\-?[0-9]+[\.][0-9]+');
            if maybe_tok is not null then
                payload := substring(payload, character_length(maybe_tok)+1, 99999);
                tokens := tokens || ('FLOAT', maybe_tok)::gql.token;
                continue;
            end if;

            maybe_tok = substring(payload from '^\-?[0-9]+');
            if maybe_tok is not null then
                payload := substring(payload, character_length(maybe_tok)+1, 99999);
                tokens := tokens || ('INT', maybe_tok)::gql.token;
                continue;
            end if;

            maybe_tok = substring(payload from '^#[^\u000A\u000D]*');
            if maybe_tok is not null then
                payload := substring(payload, character_length(maybe_tok)+1, 99999);
                continue;
            end if;

            if first_char = ',' then
                payload := substring(payload, 2, 99999);
                continue;
            end if;

            cur_token := coalesce(case
                    when first_char = '[' then ('BRACKET_L', ']')::gql.token
                    when first_char = ']' then ('BRACKET_R', '[')::gql.token
                    when first_char = '!' then ('BANG', '!')::gql.token
                    when first_char = '$' then ('DOLLAR', '$')::gql.token
                    when first_char = '&' then ('AMP', '&')::gql.token
                    when first_char = '=' then ('EQUALS', '=')::gql.token
                    when first_char = '@' then ('AT', '@')::gql.token
                    when first_char = '|' then ('PIPE', '|')::gql.token
                    when substring(payload, 1, 3) = '...' then ('SPREAD', '...')::gql.token
                    else null::gql.token
                end::gql.token,
                ('ERROR', substring(payload from '^.*'))::gql.token
            );

            payload := substring(payload, character_length(cur_token.content)+1, 99999);
            tokens := tokens || cur_token;
        end loop;
        return tokens;
    end;
$BODY$;


comment on function gql.tokenize_operation is $comment$
	Tokenizes a string containing a valid GraphQL operation
	https://graphql.github.io/graphql-spec/June2018/#sec-Language.Operations
	into an array of gql.token

	Example:
		select
			gql.tokenize_operation('
				query {
					account(id: 1) {
					# queries have comments
					id
					name
				}
			')
	Returns:
		Array[('NAME', 'query'), ('BRACE_L', '{'), ('NAME', 'account'), ...]::gql.token[]
$comment$;


/*
******************************
** File: parser.sql
** Name: Oliver Rice
** Date: 2019-12-11
** Desc: Parse a token array into an abstract syntax tree (AST)
******************************

Public API:
    - gql.parse_operation(tokens gql.token[]) returns jsonb


select
	jsonb_pretty(
		gql.parse_operation(
            gql.tokenize_operation('
                query {
                    acct: account(id: 1, name: "Oliver") {
                        id
                        photo(px: 240)
                        created_at
                    }
                }'
            ),
        )
    )
*/

create type gql.partial_parse as (
	contents jsonb,
	remaining gql.token[]
);


create or replace function gql.parse_field(tokens gql.token[]) returns gql.partial_parse
    language plpgsql immutable parallel safe
as $BODY$
    declare
        _alias text;
        _name text;
        cur jsonb;
        args jsonb := '{}';
        last_iter_args jsonb := null;
        last_iter_fields jsonb := null;
        fields jsonb := '{}';
        cur_field gql.partial_parse;
        field_depth int := 0;
        condition jsonb := '{}';
        ix int;

        include jsonb := to_jsonb(true);
        skip jsonb := to_jsonb(false);
    begin
    -- Read Alias
    if (tokens[1].kind, tokens[2].kind) = ('NAME', 'COLON') then
        _alias = tokens[1].content;
        tokens = tokens[3:];
    else
        _alias := null;
    end if;

    -- Read Name
    _name := tokens[1].content;

    
    -- Handle Inline Fragments
    -- Given that all pg_graphql endpoints only ever return one type, they are not yet supported
    if (_name, tokens[1].content) = ('...', 'on') then
            raise exception 'gql.parse_field: Inline query fragments are not necessary for this query %', tokens;
    end if;

    -- https://graphql.org/learn/queries/#fragments
    if _name = '...' then
        _name := _name || tokens[2].content;
        -- Advance past the spread marker
        tokens := tokens[2:];
    end if;

    -- Advance past name
    tokens := tokens[2:];


    -- Handle Directives
    -- https://graphql.org/learn/queries/#directives
    if tokens[1].kind = 'AT' then
        -- Looks like @<BLANK>(if: <BLANK>)
        if (tokens[3].kind, tokens[4].content, tokens[5].kind, tokens[7].kind) = ('PAREN_L', 'if', 'COLON', 'PAREN_R') 
            and tokens[2].content in ('include', 'skip') then

            include := case tokens[2].content when 'include' then to_jsonb(tokens[6].content) else include end;
            skip := case tokens[2].content when 'skip' then to_jsonb(tokens[6].content) else skip end;

        else
            raise exception 'gql.parse_field: invalid state while parsing directive %', tokens;
        end if;
        tokens := tokens[8:];

    end if;



        -- Read Args
    if tokens[1].kind = 'PAREN_L' then
        -- Skip over the PAREN_L
        tokens := tokens[2:];

        -- Find the end of the arguments clause
        -- Avoid infinite loop. ix is unused.
        for ix in (select * from generate_series(1, array_length(tokens,1))) loop
            if tokens[1].kind = 'PAREN_R' then
                tokens := tokens[2:];
                exit;
            end if;

            -- Parse condition argument 
            if (tokens[1].kind, tokens[1].content, tokens[2].kind, tokens[3].kind) = ('NAME', 'condition', 'COLON', 'BRACE_L') then
                tokens := tokens[4:];
                for ix in (select * from generate_series(1, array_length(tokens,1))) loop
                    if tokens[1].kind = 'BRACE_R' then
                        tokens := tokens[2:];
                        exit;
                    end if;
                    -- Parse a variable argument
                    if (tokens[1].kind, tokens[2].kind, tokens[3].kind) = ('NAME', 'COLON', 'DOLLAR') then
				        cur := jsonb_build_object(
                            tokens[1].content,
                            '$' || tokens[4].content
                        );
                        tokens := tokens[5:];
                    -- Parse a standard argument
                    elsif (tokens[1].kind, tokens[2].kind) = ('NAME', 'COLON') then
                        cur := jsonb_build_object(
                            tokens[1].content,
                            tokens[3].content
                        );
                        tokens := tokens[4:];
                    end if;
                    condition := condition || cur;
                end loop;

                cur := jsonb_build_object('condition', cur);

            -- Parse a variable argument
            elsif (tokens[1].kind, tokens[2].kind, tokens[3].kind) = ('NAME', 'COLON', 'DOLLAR') then
                cur := jsonb_build_object(
                    tokens[1].content,
                    '$' || tokens[4].content
                );
                tokens := tokens[5:];
            -- Parse a standard argument
            elsif (tokens[1].kind, tokens[2].kind) = ('NAME', 'COLON') then
                cur := jsonb_build_object(
                    tokens[1].content,
                    tokens[3].content
                );
                tokens := tokens[4:];
            else
                raise exception 'gql.parse_field: invalid state parsing arg with tokens %', tokens;
            end if;

            args := args || cur;
        end loop;
    else
        args := '{}'::jsonb;
    end if;

    -- Read Fields
    if tokens[1].kind = 'BRACE_L' then
        for ix in (select * from generate_series(1, array_length(tokens,1))) loop

            if (tokens[1].kind = 'BRACE_L') then
                tokens := tokens[2:];
                field_depth := field_depth + 1;
            end if;
            if (tokens[1].kind = 'BRACE_R') then
                tokens := tokens[2:];
                field_depth := field_depth - 1;
            end if;

            exit when field_depth = 0;

            cur_field := gql.parse_field(tokens);
            fields := fields || cur_field.contents;
            tokens := cur_field.remaining;
        end loop;
    else
        fields := '{}'::jsonb;
    end if;



	return (
        select
            (
		        jsonb_build_object(
                    _name, jsonb_build_object(
                    'alias', _alias,
                    'name', _name,
                    'args', args,
                    'fields', fields,
                    'include', include,
                    'skip', skip
                )),
	            tokens
	        )::gql.partial_parse
    );
    end;
$BODY$;




create or replace function gql.parse_fragments(tokens gql.token[]) returns jsonb
    language plpgsql immutable strict parallel safe
as $BODY$
/*
{   
    fragment_1: {
        "field1": # Field def,
    }
}
*/
declare
    ix int;
    fragments jsonb := '{}';

begin
    for ix in (select * from generate_series(1, array_length(tokens,1))) loop
        if (
            tokens[1].kind, tokens[1].content, tokens[2].kind,
            tokens[3].kind, tokens[3].content, tokens[4].kind,
            tokens[5].kind
           ) = (
            'NAME', 'fragment', 'NAME',
            'NAME', 'on', 'NAME', 'BRACE_L'
           ) then

            -- Make the fragemnt look like a field so we can parse it
            fragments := fragments || (
                gql.parse_field(
                    -- Make the fragemnt look like a field so we can parse it
                    ('NAME', '...' || tokens[2].content)::gql.token || tokens[5:]
                )
            ).contents; 

        end if;
        tokens := tokens[2:array_length(tokens,1)];
        exit when tokens is null;
    end loop;
    return fragments; 
end;
$BODY$;






create or replace function gql.ast_recursive_merge(a jsonb, b jsonb)
returns jsonb language sql as $$
    select 
        jsonb_object_agg(
            coalesce(ka, kb), 
            case 
                when va is null then vb 
                when vb is null then va 
                when va = vb then va
                --when jsonb_typeof(va) <> 'object' then va || vb
                when (jsonb_typeof(va) = 'object' and jsonb_typeof(vb) = 'object') then gql.ast_recursive_merge(va, vb)
                else coalesce(va, vb)
            end
        )
    from jsonb_each(a) e1(ka, va)
    full join jsonb_each(b) e2(kb, vb) on ka = kb;
$$;


CREATE or replace FUNCTION gql.ast_merge_at_key(obj jsonb, search text, substitute jsonb) RETURNS jsonb
STRICT LANGUAGE SQL AS $$
/*
Anywhere 'search' is found as a key, 'substitute' is unpacked in its place.
Intended for unpacking query fragments on an AST
 */
  SELECT
    CASE jsonb_typeof(obj)
        
        WHEN 'object' THEN
            gql.ast_recursive_merge(
                (
                    SELECT
                        jsonb_object_agg(
                            key,
                            gql.ast_merge_at_key(
                                value,
                                search,
                                substitute
                            )
                        )
                    FROM
                        jsonb_each(obj)
                    WHERE
                        key <> search
                ),
                CASE
                    -- Extract fields from the fragment into the current level
                    WHEN obj ? search THEN substitute
                    ELSE '{}'
                END
            )
        -- AST does not contain array types 
        -- WHEN 'array' THEN

        -- Scalar
        ELSE
          obj
    END;
$$;

CREATE or replace FUNCTION gql.ast_expand_fragments(ast jsonb, fragments jsonb) RETURNS jsonb
language plpgsql immutable parallel safe as
$BODY$
declare
    fragment record;
    ast_prior jsonb;
    ix int;
begin
/*
    AST Passes to populate query fragments
    --------------------------------------
    Fragments may be nested but nested fragments are
    forbidden from forming cylces in the specification
    */
    
    -- Set maximum depth of nested query fragments
    for ix in select * from generate_series(1, 10) loop
        ast_prior = ast;
        -- Expand fragments in the AST
        for fragment in select key, value from jsonb_each(fragments) loop
            ast := gql.ast_merge_at_key(ast, fragment.key, fragment.value -> 'fields');
        end loop;
        -- If nothing happend, we're done
        if ast = ast_prior then
            exit;
        end if;
    end loop;
    return ast;
end;
$BODY$;




CREATE or replace FUNCTION gql.ast_replace_value(ast jsonb, search jsonb, substitute jsonb) RETURNS jsonb
STRICT LANGUAGE plpgsql AS $$
/*
Anywhere 'search' is found as a key, 'substitute' is unpacked in its place.
Intended for unpacking query fragments on an AST
 */
 begin
  return
    CASE jsonb_typeof(ast)
        WHEN 'object' THEN
          (
            SELECT
                jsonb_object_agg(
                    key,
                    gql.ast_replace_value(value, search, substitute)
                )
            FROM
                jsonb_each(ast)
          )
        -- AST does not contain array types 
        -- WHEN 'array' THEN
        -- TODO(OR): A literal string argument passed as a 
        when 'string' then case when ast = search then substitute else ast end
        else ast
    end;
end;
$$;




CREATE or replace FUNCTION gql.ast_substitute_variables(ast jsonb, variables jsonb) RETURNS jsonb
language plpgsql immutable parallel safe as
$BODY$
declare
    variable record;
begin
    -- AST Pass to populate variables
    for variable in select key, value from jsonb_each(variables) loop
        ast := gql.ast_replace_value(
            ast := ast,
            search := to_jsonb(('$' || variable.key)::text),
            substitute := variable.value
        );
    end loop;

    return ast;
end;
$BODY$;







create or replace function gql.to_bool(jsonb) returns bool
language plpgsql immutable as 
$$
begin
    return
        case
            when $1 = to_jsonb('true'::text) then true
            when $1 = to_jsonb('false'::text) then false
            when $1 = to_jsonb(true::bool) then true
            when $1 = to_jsonb(false::bool) then false
        end;
end;
$$;



create or replace function gql.ast_is_skip(ast jsonb) returns bool
language plpgsql immutable as
$$
begin
    return
        case
            when (jsonb_typeof(ast) = 'object'
                    and ast ? 'fields'
                    and ast ? 'args'
                    and ast ? 'include'
                    and ast ? 'skip'
                ) then gql.to_bool(ast -> 'include') and not gql.to_bool(ast -> 'skip')
            else true
        end;
end;
$$;


CREATE or replace FUNCTION gql.ast_apply_directives(ast jsonb) RETURNS jsonb
STRICT LANGUAGE plpgsql AS $$
begin
/*
Skip fields where skip = true or include = false
 */
  return
    CASE 
        WHEN jsonb_typeof(ast) = 'object' THEN
            (
            SELECT
                jsonb_object_agg(
                    key,
                    gql.ast_apply_directives(value)
                )
            FROM
                jsonb_each(ast)
            WHERE
                gql.ast_is_skip(value)
            )
        else ast
    end;
end;
$$;


/*
******************************
** File: cursor.sql
** Name: Oliver Rice
** Date: 2019-12-11
** Desc: Parse a token array into an abstract syntax tree (AST)
******************************

*/


create or replace function gql.to_cursor_type_name(_table_name text) returns text
	language sql immutable as
$$ select 'gql.' || _table_name || '_cursor';
$$;



CREATE OR REPLACE FUNCTION gql.build_cursor_types(_table_schema text) RETURNS void
    LANGUAGE 'plpgsql'
AS $BODY$
	declare
		rec record;
        func_def text;
        col_clause text;
	begin
		for rec in select * from gql.table_info ti where ti.table_schema=table_schema loop

            
            select
                string_agg(ci.column_name || ' ' || ci.sql_data_type, ', ' order by ci.ordinal_position)
            from
                gql.column_info ci
            where
                rec.table_schema=ci.table_schema and rec.table_name=ci.table_name
                and ci.is_pkey
            into col_clause;

            func_def := format(e'create type %s as (%s);',
                gql.to_cursor_type_name(rec.table_name), col_clause
            );

			execute func_def;
			
        end loop;
    end;
$BODY$;
			

CREATE OR REPLACE FUNCTION gql.build_resolve_cursor(_table_schema text) RETURNS void
    LANGUAGE 'plpgsql'
AS $BODY$
	declare
		rec record;
        func_def text;
        col_clause text;
	begin
		for rec in select * from gql.table_info ti where ti.table_schema=table_schema loop

            
            select
                string_agg('rec.' || ci.column_name, ', ' order by ci.ordinal_position)
            from
                gql.column_info ci
            where
                rec.table_schema=ci.table_schema and rec.table_name=ci.table_name
                and ci.is_pkey
            into col_clause;

            func_def := format(e'
create or replace function gql.resolve_cursor(rec %s.%s) returns %s
language plpgsql immutable
as $$
begin
    return row(%s)::%s; 
end;
$$;',
rec.table_schema, rec.table_name, gql.to_cursor_type_name(rec.table_name),
col_clause, gql.to_cursor_type_name(rec.table_name)
);

			execute func_def;
        end loop;
    end;
$BODY$;



create or replace function gql.record_to_cursor_select_clause(_table_schema text, _table_name text, rec_name text default 'rec') RETURNS text
    LANGUAGE sql immutable as
$$ 
-- For selecting a cursor from a record to return to a user. Not suitable for filtering
-- Due to inability to work with indexes
select format(e'gql.resolve_cursor(%s::%s.%s)::text', rec_name, _table_schema, _table_name);
$$;



CREATE OR REPLACE FUNCTION gql.to_cursor_clause(
    _table_schema text,
    _table_name text,
    source_name text,
    as_row bool default true 
) returns text
    LANGUAGE 'plpgsql'
AS $BODY$
    -- creates an entry to a select clause to select primary key values
    -- as cursor. Use 'as_row' to determine if the result is packed into
    -- a row() call
	declare
        col_clause text;
	begin
        select
            string_agg(source_name || '.' || ci.column_name, ', ' order by ci.ordinal_position)
        from
            gql.column_info ci
        where
            _table_schema=ci.table_schema and _table_name=ci.table_name
            and ci.is_pkey
        into col_clause;
        
        if as_row then
            return format(e'row(%s)', col_clause);
        end if;
        return format(e'(%s)', col_clause);

    end;
$BODY$;


CREATE OR REPLACE FUNCTION gql.text_to_cursor_clause(
    _table_schema text,
    _table_name text,
    source_name text default 'after_cursor'
) returns text
    LANGUAGE 'plpgsql'
AS $BODY$
	declare
        col_clause text;
	begin
        select 
            string_agg('(abc.r).' || ci.column_name, ', ' order by ci.ordinal_position)
        from
            gql.column_info ci
        where
            _table_schema=ci.table_schema and _table_name=ci.table_name
            and ci.is_pkey
        into col_clause;
        
        return format(e'(select (%s) from (select (%s::%s)) abc(r))',
                col_clause,
                source_name,
                gql.to_cursor_type_name(_table_name)
        );


    end;
$BODY$;


/*
******************************
** File: resolver.sql
** Name: Oliver Rice
** Date: 2019-12-11
** Desc: Build a SQL query from a parsed GraphQL AST
******************************


Public API:
    - gql.execute(operation: text) returns jsonb
*/

create or replace function gql.to_resolver_name(field_name text) returns text as
$$ select 'gql."resolve_' || field_name || '"'
$$ language sql immutable returns null on null input;



create or replace function gql.to_field_selector_clause(gql.column_info) returns text
	language sql stable as
$$
	select format(
		e'case when field #> \'{fields,%s}\' is not null then jsonb_build_object(coalesce(field #>> \'{fields,%s,alias}\', field #>> \'{fields,%s,name}\'), rec.%s) else \'{}\' end',
		gql.to_field_name($1.column_name),
		gql.to_field_name($1.column_name),
		gql.to_field_name($1.column_name),
		$1.column_name
	);
$$;


create or replace function gql.to_field_selector_clause(gql.relationship_info) returns text
	language plpgsql stable as
$$
declare
	field_name text := gql.relationship_to_gql_field_name($1.constraint_name);
	resolver_name text := gql.to_resolver_name(field_name);
begin
	return format(
		e'case when field #> \'{fields,%s}\' is not null then %s(rec := rec, field := field #> \'{fields,%s}\') else \'{}\' end',
		field_name,
		resolver_name,
		field_name
	);
end;
$$;


create or replace function gql.build_resolve_rows(_table_schema text) returns void
	language plpgsql as
$body$
	declare
		tab_rec record;
		func_def text;
        cursor_selector text;
        selector text;
	begin
		for tab_rec in select * from gql.table_info ci where ci.table_schema=table_schema loop

			cursor_selector := gql.record_to_cursor_select_clause(tab_rec.table_schema, tab_rec.table_name, 'rec');

            select string_agg(s_clause, e'\n || ')
            from
            (
                -- Columns
                select gql.to_field_selector_clause(ci) s_clause
                from gql.column_info ci
                where
                    ci.table_schema=tab_rec.table_schema
                    and ci.table_name = tab_rec.table_name
                
                union all
                -- Relationships
                select gql.to_field_selector_clause(ri) s_clause
                from gql.relationship_info ri
                where
                    ri.table_schema=tab_rec.table_schema
                    and ri.local_table = tab_rec.table_name
            ) abc(s_clause)
            into selector;

            
		
			func_def := format(e'
create or replace function %s(rec %s.%s, field jsonb)
    returns jsonb
    language plpgsql
    immutable
    parallel safe
    as
$$
begin
    return jsonb_build_object(
                   coalesce(field ->> \'alias\', field ->> \'name\'), (
                        -- NodeId
                        case when field #> \'{fields,nodeId}\' is not null
                             then jsonb_build_object(
                                coalesce(
                                    field #>> \'{fields,nodeId,alias}\',
                                    field #>> \'{fields,nodeId,name}\'
                                ),
                                %s
                             )
                             else \'{}\'::jsonb
                             end ||
%s
                   )
            );
end;
$$;',
                gql.to_resolver_name(gql.to_base_name(tab_rec.table_name)), tab_rec.table_schema, tab_rec.table_name,
                cursor_selector, selector
            );
            raise notice 'Function %', func_def;
			execute func_def;
		end loop;
	end;
$body$;




create or replace function gql.build_resolve_entrypoint_one(_table_schema text) returns void
	language plpgsql as
$body$
	declare
		tab_rec record;
		func_def text;
		resolver_name text;
		cursor_arg_parsed text;
        cursor_selector text;
	begin
		for tab_rec in select * from gql.table_info ci where ci.table_schema=table_schema loop
			
            cursor_arg_parsed := gql.text_to_cursor_clause(
                tab_rec.table_schema,
                tab_rec.table_name,
                e'(field #>> \'{args,nodeId}\')'
            );

            cursor_selector := gql.to_cursor_clause(
                tab_rec.table_schema,
                tab_rec.table_name,
                'tab',
                as_row := false
            );


			
			func_def := format(e'
			create or replace function %s(field jsonb)
				returns jsonb
				language plpgsql
			    immutable
				parallel safe
				as
			$$
            begin
				return
                    jsonb_build_object(
                        coalesce(field->>\'alias\', field->>\'name\'),
					    %s(tab, field) -> coalesce(field->>\'alias\', field->>\'name\')
                    )
				from
					%s.%s tab
				where
					%s = %s
				limit 1;
            end;
		   $$;', gql.to_resolver_name(gql.to_entrypoint_one_name(tab_rec.table_name)),
			   gql.to_resolver_name(gql.to_base_name(tab_rec.table_name)),
			   tab_rec.table_schema, tab_rec.table_name,
			   cursor_selector, cursor_arg_parsed

			);
			--raise notice 'Function %', func_def;
			execute func_def;
		end loop;
	end;
$body$;

create or replace function gql.build_resolve_entrypoint_connection(_table_schema text) returns void
	language plpgsql as
$body$
	declare
		tab_rec record;
		func_def text;
		resolver_name text;
		pkey_col text;
		pkey_clause text := '';
	begin
		for tab_rec in select * from gql.table_info ci where ci.table_schema=table_schema loop

			
			func_def := format(e'
			create or replace function %s(field jsonb)
				returns jsonb
				language plpgsql
			    immutable
				parallel safe
				as
			$$
            begin
				return
                    jsonb_build_object(
                        coalesce(field->>\'alias\', field->>\'name\'),
                        %s(field) -> coalesce(field->>\'alias\', field->>\'name\')
                    );
            end;
		   $$;', gql.to_resolver_name(gql.to_entrypoint_connection_name(tab_rec.table_name)),
			   gql.to_resolver_name(gql.to_connection_name(tab_rec.table_name))
            );
			--raise notice 'Function %', func_def;
			execute func_def;
		end loop;
	end;
$body$;



create or replace function gql.build_resolve(_table_schema text) returns void
	language plpgsql as
$body$
	declare
		rec record;
		func_def text;
		field_name text;
		resolver_name text;
	begin
		func_def := '
			create or replace function gql.resolve(field jsonb)
				returns jsonb
				language plpgsql
			    immutable
				parallel safe
				as
			$$
            declare
                val_to_match text := (select * from jsonb_object_keys(field) limit 1);
            begin
			return 
				case 
			';
		for rec in select * from gql.table_info ci where ci.table_schema=table_schema loop
			field_name := gql.to_entrypoint_one_name(rec.table_name);
			resolver_name := gql.to_resolver_name(field_name);
			func_def := func_def || format(e'
				when val_to_match = \'%s\' then %s(field := field -> \'%s\')',
			field_name, resolver_name, field_name);

            field_name := gql.to_entrypoint_connection_name(rec.table_name);
			resolver_name := gql.to_resolver_name(field_name);
			func_def := func_def || format(e'
				when val_to_match = \'%s\' then %s(field := field -> \'%s\')',
			field_name, resolver_name, field_name);

		end loop;
			
        func_def := func_def || e'\nelse \'{"error": "no resolver matched"}\'::jsonb end; end;$$;';
		--raise notice 'Function %', func_def;
		execute func_def;
	end;
$body$;




CREATE OR REPLACE FUNCTION gql.build_resolve_connections(_table_schema text) RETURNS void
    LANGUAGE 'plpgsql'
AS $BODY$
	declare
		rec record;
		col_rec record;
		tab_rec gql.table_info;
		join_clause text;
		condition_clause text;
		order_clause text;
		cursor_extractor text;
		pagination_clause text;
		cursor_selector text;
		start_cursor_selector text;
        end_cursor_selector text;
		cursor_type_name text;
		func_def text;
		resolver_function_args text;
		ix int;
        template text;
		
	begin


            template := e'
create or replace function %s(%s) returns jsonb
	language plpgsql stable as
$$
declare
	-- Convenience
	field_name text := coalesce(field ->> \'alias\', field->> \'name\'); 

	-- Pagination
	arg_first int := (field #>> \'{args,first}\')::int;
	arg_last int := (field #>> \'{args,last}\')::int;
	before_cursor %s := (field #>> \'{args,before}\')::%s;
	after_cursor %s :=  (field #>> \'{args,after}\')::%s;
    row_limit int := least(coalesce(arg_first, arg_last), 20);

	-- Conditions
	filter_condition jsonb := (field #> \'{args,condition}\');

	-- Selection Set
	has_cursor bool := field #>> \'{fields,edges,fields,cursor}\' is not null;
	has_node bool := field #>> \'{fields,edges,fields,node}\' is not null;
	has_total bool := field #>> \'{fields,total_count}\' is not null;
	has_edges bool := field #>> \'{fields,edges}\' is not null;
	has_page_info bool := field #>> \'{fields,pageInfo}\' is not null;
    has_next_page bool := field #>> \'{fields,pageInfo,fields,hasNextPage}\' is not null;
    has_prev_page bool := field #>> \'{fields,pageInfo,fields,hasNextPage}\' is not null;
    has_start_cursor bool := field #>> \'{fields,pageInfo,fields,startCursor}\' is not null;
    has_end_cursor bool := field #>> \'{fields,pageInfo,fields,endCursor}\' is not null;

	edges jsonb := field #> \'{fields,edges}\';
	node jsonb := edges #> \'{fields,node}\';

	page_info_field_name text := coalesce(field #>> \'{fields,pageInfo,alias}\', \'pageInfo\');
	cursor_field_name text := coalesce(edges #>> \'{fields,cursor,alias}\', \'cursor\');
    edges_field_name text := coalesce(edges ->> \'alias\', \'edges\');
	node_field_name text := coalesce(edges #>> \'{fields,node,alias}\', \'node\');
	next_page_field_name text := coalesce(field #>> \'{fields,pageInfo,fields,hasNextPage,alias}\', \'hasNextPage\');
	previous_page_field_name text := coalesce(field #>> \'{fields,pageInfo,fields,hasPreviousPage,alias}\', \'hasPreviousPage\');
    start_cursor_field_name text := coalesce(field #>> \'{fields,pageInfo,fields,startCursor,alias}\', \'startCursor\');
    end_cursor_field_name text := coalesce(field #>> \'{fields,pageInfo,fields,endCursor,alias}\', \'endCursor\');
	total_field_name text := coalesce(field #>> \'{fields,total_count,alias}\', \'total_count\');
							   
begin
	-- Compute total
    return ( 
        with total as (
            select
				count(*) total_count
			from
				%s.%s
			where
				-- Join Clause
				%s
				-- Conditions
				%s
                -- Skip if not requested
                and has_total
        ),
        -- Query for rows and apply pagination
		subq as (
			select
				*
			from
            %s.%s
			where
				-- Join Clause
				%s
				-- Pagination
				%s
				-- Conditions
				%s
			order by
				case when before_cursor is not null or arg_last is not null then %s end desc,
				%s asc
			limit
                -- Retrieve extra row to check if there is another page
				row_limit + 1
		),
        
        -- Ensure deterministic sort order
		subq_sorted as (
			select * from subq order by %s asc limit row_limit
		),
        -- Check if has next page
        has_next as (
            select (select count(*) from subq) > row_limit as val
        ),
        -- Check if has previous page
        has_previous as (
            select 
                case
                    -- If a cursor is provided, that row appears on the previous page
                    when coalesce(before_cursor, after_cursor) is not null then true
                    -- If no cursor is provided, no previous page
                    else false
                end val
        ),
        -- Page Info Cursors
        start_cursor as (
            select
                %s::text as val
            from 
                subq_sorted
            order by
                %s asc
            limit 1
        ),
        end_cursor as (
            select
                %s::text as val
            from 
                subq_sorted
            order by
                %s desc
            limit 1
        )
        -- Build result
		select jsonb_build_object(
			field_name,
			( select
                case
                    when has_edges then jsonb_build_object(
                        edges_field_name, jsonb_agg(
                            case when has_cursor then jsonb_build_object(
                                cursor_field_name,
                                %s::text) else \'{}\'::jsonb end ||
                            case when has_node then %s(
                                    rec:=subq_sorted,
                                    field:=node
                                    ) else \'{}\'::jsonb end 
                        )
                    )
                    else \'{}\'::jsonb
                end ||
                case
                    when has_total is not null then jsonb_build_object(total_field_name, (select total_count from total))
                    else \'{}\'::jsonb
                end ||
                case
                    when has_page_info then jsonb_build_object(
                        page_info_field_name, ( 
                            case
                                when has_next_page then jsonb_build_object(
                                    next_page_field_name, (select val from has_next)
                                ) 
                                else \'{}\'::jsonb
                            end ||
                            case
                                when has_prev_page then jsonb_build_object(
                                    previous_page_field_name, (select val from has_previous)
                                )
                            else \'{}\'::jsonb
                            end ||
                            case
                                when has_start_cursor then jsonb_build_object(
                                    start_cursor_field_name, (select val from start_cursor)
                                ) else \'{}\'::jsonb
                            end ||
                            case
                                when has_end_cursor then jsonb_build_object(
                                    end_cursor_field_name, (select val from end_cursor)
                                )  else \'{}\'::jsonb
                            end 
                        )
                    ) 
                    else \'{}\'::jsonb
                end

			)
		)
		from
			subq_sorted
	);
end;
$$;';


		for tab_rec in (select * from gql.table_info ti where ti.table_schema=_table_schema) loop


            -- Condition Clause
            condition_clause := '';
            for col_rec in (
                select *
                from gql.column_info ci
                where ci.table_schema=tab_rec.table_schema
                    and ci.table_name=tab_rec.table_name
                ) loop

                condition_clause := condition_clause || format(
                    e'and coalesce(%s = (filter_condition ->> \'%s\')::%s, true)\n',
                    col_rec.column_name, gql.to_field_name(col_rec.column_name), col_rec.sql_data_type
                );
            end loop;
            
            
            -- Ordering Clause
            order_clause := (select '(' || string_agg(x, ',') || ')' from unnest(tab_rec.pkey_cols) abc(x));
            
            -- Pagination Clause
            cursor_type_name := gql.to_cursor_type_name(tab_rec.table_name);
            cursor_extractor := gql.text_to_cursor_clause(
                tab_rec.table_schema,
                tab_rec.table_name,
                'after_cursor'
            );
            
            pagination_clause := format(e'and coalesce(%s > %s, true)\n', order_clause, cursor_extractor);
            cursor_extractor := gql.text_to_cursor_clause(
                tab_rec.table_schema,
                tab_rec.table_name,
                'before_cursor'
            );
            pagination_clause := pagination_clause || format(e'\t\t\t\tand coalesce(%s > %s, true)\n', order_clause, cursor_extractor);
            
            -- Cursor Selector
            cursor_selector := gql.to_cursor_clause(tab_rec.table_schema, tab_rec.table_name, 'subq_sorted');
            
            -- Function Signature
            resolver_function_args := 'field jsonb';

            -- Entrypoint Connection
			func_def := format(template,
                gql.to_resolver_name(gql.to_connection_name(tab_rec.table_name)),
                resolver_function_args,
                cursor_type_name, cursor_type_name, cursor_type_name, cursor_type_name, 
                tab_rec.table_schema, tab_rec.table_name,
                'true', condition_clause,
                tab_rec.table_schema, tab_rec.table_name, 'true', pagination_clause, condition_clause,
                order_clause, order_clause, order_clause,
                cursor_selector, order_clause,
                cursor_selector, order_clause,
                cursor_selector, gql.to_resolver_name(gql.to_base_name(tab_rec.table_name))		
            );
			execute func_def;

            -- For each relationship, make a connection resolver
            for rec in select *
                    from gql.relationship_info ri
                    where ri.table_schema = tab_rec.table_schema
                            and ri.foreign_table = tab_rec.table_name
				            and ri.foreign_cardinality = 'MANY' loop
			
                -- Build Join Clause
                join_clause := '';
                for ix in select generate_series(1, array_length(rec.local_columns, 1)) loop
                    join_clause := join_clause || format('rec.%s = %s.%s and ',
                                                         rec.local_columns[ix],
                                                         rec.foreign_table,
                                                         rec.foreign_columns[ix]);
                end loop;
                join_clause := substring(join_clause, 1, character_length(join_clause)-4);
                
                
                -- Function Signature
                resolver_function_args := format(
                    'rec %s.%s, field jsonb',
                    rec.table_schema,
                    rec.local_table
                );
                
                
                func_def := format(template,
                    gql.to_resolver_name(gql.relationship_to_gql_field_name(rec.constraint_name)),
                    resolver_function_args,
                    cursor_type_name, cursor_type_name, cursor_type_name, cursor_type_name, 
                    rec.table_schema, rec.foreign_table,
                    join_clause, condition_clause,
                    rec.table_schema, rec.foreign_table, join_clause, pagination_clause, condition_clause,
                    order_clause, order_clause, order_clause,
                    cursor_selector, order_clause,
                    cursor_selector, order_clause,
                    cursor_selector, gql.to_resolver_name(gql.to_base_name(rec.foreign_table))		
                );

                --raise notice 'Function %', func_def;
                execute func_def;

		    end loop;
		end loop;
	end;
$BODY$;



CREATE OR REPLACE FUNCTION gql.build_resolve_relationship_to_one(_table_schema text) RETURNS void
    LANGUAGE 'plpgsql'
AS $BODY$
	declare
		rec record;
		join_clause text;
		func_def text;
		ix int;
        template text;
		
    begin

            template := e'
create or replace function %s(rec %s.%s, field jsonb) returns jsonb
	language plpgsql stable as
$$
begin
	-- Compute total
    return ( 
		select
            %s(
                rec:=%s,
                field:=field
            )
		from
			%s.%s
        where
            -- Join clause
            %s
        -- Only returns 1 row due to join clause
        limit 1
    );
end;
$$;';


            -- For each relationship, make a connection resolver
        for rec in select *
                from gql.relationship_info ri
                where ri.table_schema = _table_schema
                        and ri.foreign_cardinality = 'ONE' loop
        
                -- Build Join Clause
                join_clause := '';
                for ix in select generate_series(1, array_length(rec.local_columns, 1)) loop
                    join_clause := join_clause || format('rec.%s = %s.%s and ',
                                                         rec.local_columns[ix],
                                                         rec.foreign_table,
                                                         rec.foreign_columns[ix]);
                end loop;
                join_clause := substring(join_clause, 1, character_length(join_clause)-4);
 
            -- Entrypoint Connection
			func_def := format(template,
                gql.to_resolver_name(gql.relationship_to_gql_field_name(rec.constraint_name)),
                rec.table_schema, rec.local_table,
                gql.to_resolver_name(gql.to_base_name(rec.foreign_table)),
                rec.foreign_table,
                rec.table_schema, rec.foreign_table,
                join_clause
            );
			execute func_def;
        end loop;
	end;
$BODY$;


create or replace function gql.build_resolve_stubs(_table_schema text) returns void
	language plpgsql as
$body$
	declare
		rec record;
		func_def text;
		resolver_name text;
	begin
		for rec in select * from gql.table_info ci where ci.table_schema=table_schema loop

            -- Row Resolver
            resolver_name := gql.to_resolver_name(gql.to_base_name(rec.table_name));
			func_def := format(e'
create or replace function %s(rec %s.%s, field jsonb) returns jsonb
language plpgsql stable as
$$ begin raise notice \'Resolved by stub. You must build resolvers\'; return null::jsonb; end;
$$;', resolver_name, rec.table_schema, rec.table_name);
			execute func_def;

            -- Connection Resolver
            resolver_name := gql.to_resolver_name(gql.to_connection_name(rec.table_name));
			func_def := format(e'
create or replace function %s(field jsonb) returns jsonb
language plpgsql stable as
$$ begin raise notice \'Resolved by stub. You must build resolvers\'; return null::jsonb; end;
$$;', resolver_name, rec.table_schema, rec.table_name);
			execute func_def;
            
		end loop;

        -- Relationship Resolver
		for rec in select * from gql.relationship_info ci where ci.table_schema=table_schema loop
            resolver_name := gql.to_resolver_name(gql.relationship_to_gql_field_name(rec.constraint_name));
			func_def := format(e'
create or replace function %s(rec %s.%s, field jsonb) returns jsonb
language plpgsql stable as
$$ begin raise notice \'Resolved by stub. You must build resolvers\'; return null::jsonb; end;
$$;', resolver_name, rec.table_schema, rec.local_table);
			execute func_def;
		end loop;
	end;
$body$;


create or replace function gql.build_resolvers(_table_schema text) returns void
	language plpgsql stable as
$$
	begin
		perform gql.build_resolve_stubs(_table_schema);
		perform gql.build_cursor_types(_table_schema);
		perform gql.build_resolve_cursor(_table_schema);
		perform gql.build_resolve_connections(_table_schema);
        perform gql.build_resolve_relationship_to_one(_table_schema);
		perform gql.build_resolve_rows(_table_schema);
		perform gql.build_resolve_entrypoint_one(_table_schema);
		perform gql.build_resolve_entrypoint_connection(_table_schema);
		perform gql.build_resolve(_table_schema);
	end;
$$;


create or replace function gql.drop_resolvers() returns void
	language plpgsql 
as $body$
declare
	function_oid text;
	type_oid text;
begin

	-- Drop resolver functions
	for function_oid in (
		select
			p.oid::regprocedure --,
		from 
			pg_catalog.pg_namespace n
			join pg_catalog.pg_proc p
				on pronamespace = n.oid
		where
			nspname = 'gql'
			and proname like 'resolve_%') loop
	    execute format('drop function if exists %s;', function_oid);
    end loop;

    for type_oid in (
        select 
            t.oid::regtype
        from
            pg_type t
            inner join pg_namespace n on t.typnamespace = n.oid
        where
            n.nspname = 'gql'
            and typname like '%_cursor'
            and typcategory = 'C'
        ) loop
	    execute format('drop type %s;', type_oid);
	end loop;
end;
$body$;




create or replace function gql.parse_operation(tokens gql.token[], variables jsonb default '{}'::jsonb) returns jsonb
    language plpgsql immutable strict parallel safe
as $BODY$
declare
    ast jsonb;
    fragments jsonb := gql.parse_fragments(tokens);
    ix int;
begin

    
    ------------------------
    ------- QUERIES --------
    ------------------------

    -- Standard syntax: "query { ..."
    if (tokens[1].kind, tokens[2].kind) = ('NAME', 'BRACE_L') and tokens[1].content = 'query'
        then tokens := tokens[3:];
    end if;

    -- Simplified syntax for single queries: "{ ..."
    if tokens[1].kind = 'BRACE_L'
        then tokens := tokens[2:];
    end if;


    -- Named Operation, possibly with variables
    -- Ignore everything until the opening bracket. Query is already validated.
    -- Ex: query GetPostById($post_nodeId: ID! = something)
    if (tokens[1].kind, tokens[2].kind) = ('NAME', 'NAME') and tokens[1].content = 'query' then
        for ix in select * from generate_series(1, array_length(tokens, 1)) loop
            tokens := tokens[2:];
            exit when tokens[1].kind = 'BRACE_L';
        end loop;
        tokens := tokens[2:];
    end if;


    ---------------------------------
    --------- MUTATIONS -------------
    ---------------------------------
    -- TODO(OR)

    -- Parse request
    ast := (gql.parse_field(tokens)).contents;

    -- Expand query fragments
    ast := gql.ast_expand_fragments(ast, fragments); 

    -- Insert variable values
    ast := gql.ast_substitute_variables(ast, variables); 

    -- Apply skip and include directives
    ast := gql.ast_apply_directives(ast); 

    return ast;
end;
$BODY$;






create or replace function gql.execute(operation text, variables text default '{}') returns jsonb as
$$
    declare
        vars jsonb := variables::jsonb;
        tokens gql.token[] := gql.tokenize_operation(operation);
        ast jsonb := gql.parse_operation(tokens, vars);
    begin
        -- Raising these notices takes about 0.1 milliseconds
		--raise notice 'Tokens %', tokens::text;
        return gql.resolve(ast);
	end;
$$ language plpgsql stable;


