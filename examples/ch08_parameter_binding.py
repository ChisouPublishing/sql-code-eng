"""Chapter 8: compare string concatenation and parameter binding in a temporary table."""
# codes/sql-code-eng/examples/ch08_parameter_binding.py@v1.2.2
import os
import psycopg

with psycopg.connect(os.environ['SAKURA_DSN']) as conn:
    with conn.cursor() as cur:
        cur.execute('CREATE TEMP TABLE binding_demo (name text PRIMARY KEY)')
        cur.executemany(
            'INSERT INTO binding_demo (name) VALUES (%s)',
            [('Alice',), ("Tom's Shop",), ('Bob',)],
        )
        value = "' OR TRUE --"
        unsafe_sql = "SELECT name FROM binding_demo WHERE name = '" + value + "'"
        cur.execute(unsafe_sql)
        print('String concatenation:', len(cur.fetchall()))
        cur.execute('SELECT name FROM binding_demo WHERE name = %s', (value,))
        print('Parameter binding:', len(cur.fetchall()))
        cur.execute('SELECT name FROM binding_demo WHERE name = %s', ("Tom's Shop",))
        print('Name containing a quote:', cur.fetchone()[0])
        # Identifiers do not belong in value placeholders. Restrict choices first.
        choices = {'name order': 'name'}
        sort_column = choices['name order']
        query = psycopg.sql.SQL('SELECT name FROM binding_demo ORDER BY {}').format(
            psycopg.sql.Identifier(sort_column)
        )
        cur.execute(query)
        print('Sorting by an allowed column:', len(cur.fetchall()))
    conn.rollback()
