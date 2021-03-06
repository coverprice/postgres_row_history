### Using with Django

This guide describes how to install and use the sample code in a Django application.
(The sample code doesn't have any Django-specific support.)

#### Installation

1. Create an empty migration

```bash
$ ./manage.py makemigrations --empty some_app_name
Migrations for 'some_app_name':
  some_app_name/migrations/0002_auto_20220302_2053.py
```

This will create a skeleton source file like so:

```python
# Generated by Django 3.2 on 2022-03-03 04:53

from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('some_app_name', '0001_initial'),
    ]

    operations = [
    ]
```

2. Edit this file and add the following lines.

```python
# Generated by Django 3.2 on 2022-03-03 04:53

from django.db import migrations

INSTALL_LOGGER_SQL = """
    <in this string, copy the contents of install.sql verbatim>
"""
UNINSTALL_LOGGER_SQL = """
    <in this string, copy the contents of uninstall.sql verbatim>
"""


class Migration(migrations.Migration):

    dependencies = [
        ('some_app_name', '0001_initial'),
    ]

    operations = [
        migrations.RunSQL(sql=INSTALL_LOGGER_SQL, reverse_sql=UNINSTALL_LOGGER_SQL),
    ]
```

As an alternative to copy/pasting `install.sql` and `uninstall.sql` into the source,
you can read them at runtime with something like:

```python
from pathlib import Path
INSTALL_SQL = Path(__file__).parent.joinpath('path/to/install.sql').read_text()
UNINSTALL_LOGGER_SQL = Path(__file__).parent.joinpath('path/to/uninstall.sql').read_text()
```

3. Add the generated Python migration to your source control. e.g.

`git add some_app_name/migrations/0002_auto_20220302_2053.py`


#### Configuring

This section shows how to configure the logger on a specific table. This example uses
the "delta" approach on the the table `test_data`. The column `test_id` is always included in
the changelog, `col_to_ignore_updates` is ignored during `UPDATE`s, and `col_to_always_ignore`
is never logged.

1. Create an empty migration.

(Refer to the example above for the command to do this)

2. Edit the generated code to add the installation SQL.

```python
    operations = [
        migrations.RunSQL(
            sql="""
				SELECT enable_changeset_tracking_delta
					( 'test_data'::regclass         -- table to enable
					, '{"test_id"}'                 -- primary key IDs (always logged)
					, '{"col_to_ignore_updates"}'   -- ignore these only when updating
					, '{"col_to_always_ignore"}'    -- ignore these always
				  )
            """,
            reverse_sql="""
                SELECT disable_changeset_tracking_delta('test_data'::regclass)
            """,
        ),
    ]
```

3. Add the generated Python migration to your source control.

#### Run the migrations

```bash
./manage.py migrate --no-input
```

#### Using the logger from the application

To modify the application to use the logger, ensure:
1. The writes are wrapped in a transaction.
2. The `changeset_new()` stored procedure is called to set up the changeset metadata.

**Before**:
```python
def update_product_name(product: ProductModel, new_name: str) -> None:
    model.name = new_name
    model.save()
```


**After**:
```python
from django.db import transaction, connection
import json

def update_product_name(updater_user_name: str, product: ProductModel, new_name: str) -> None:
    with transaction.atomic():
        with connection.cursor() as cursor:
            # Create the metadata about this change's who / when / what
            params = {
               "product_id": product.id,
            }
            cursor.callproc('changeset_new', [f"Updating product", json.dumps(params), updater_user_name])
        model.name = new_name
        model.save()
```

Notes:
- The new method takes a new `updater_user_name` parameter, so that the `changeset_new()` can record
  who is making this change.
- `@transaction.atomic` can also be used as a function decorator.
- See: https://docs.djangoproject.com/en/4.0/topics/db/transactions/
- See: https://docs.djangoproject.com/en/4.0/topics/db/sql/#calling-stored-procedures
