# Data dictionary (auto-updated)

`Docs/DataDictionary/Data_Dictionary_OPD_LAB_Pharmacy_Accounts_Inventory.docx` is generated from the live database
(Dev_EMR) and this folder's configuration. It is refreshed automatically after a commit that touches
`SQLScripts/`, and can be refreshed by hand at any time.

## How it stays current

| Event | What happens |
|---|---|
| A column / table / FK / default is added, changed or dropped | Picked up from the database on the next refresh, listed in the revision history (`New table ...`, `X: new column(s) ...`, `X.c: type int -> bigint` ...) |
| A **new table** whose name fits a part (e.g. `Ph*` → Pharmacy, `Lab*` → LAB, `Acc_*` → Accounts) | Listed under "*Other <part> tables (not yet grouped)*" with its columns and inferred relations until it is placed in a module |
| Descriptions | Taken from `MS_Description` on the table / column (best: add it in the SQL script), else from `dd_config.py`, else generated from the name |
| A module is reworked or a new module is created | Edit `dd_config.py` (module list, table purposes, code meanings) — the next refresh rebuilds and records "Descriptions / module grouping updated" |

Files in `Docs/DataDictionary/` (all committed):

* `schema_snapshot.json` – the schema the document was built from (the baseline for detecting changes)
* `revision_history.json` – version, date and changes; printed in the document's Revision history
* `build_state.json` – hashes used to skip rebuilding when nothing changed

## Commands

```bash
python3 Tools/datadictionary/update_data_dictionary.py              # refresh when anything changed
python3 Tools/datadictionary/update_data_dictionary.py --check      # exit 1 if out of date or tables are ungrouped
python3 Tools/datadictionary/update_data_dictionary.py --offline    # rebuild from the snapshot (no database)
python3 Tools/datadictionary/update_data_dictionary.py --no-revision  # rebuild without a history entry (layout changes)
```

The connection comes from `EMR_DD_CONNECTION` or `ConnectionStrings:DefaultConnection` in `EMR.Web/appsettings.json`.

## One-time set-up per machine

```bash
pip3 install -r Tools/datadictionary/requirements.txt
sh Tools/datadictionary/install_hooks.sh
```

The hook runs after every commit that changes `SQLScripts/` or this folder: it reads the schema (about 15 s) and, if
the dictionary changed, makes a follow-up commit "Docs: data dictionary refreshed (auto)". Skip it for one commit
with `DD_SKIP=1 git commit ...`. If the database cannot be reached the commit is not affected.

**Order matters:** apply the SQL script to the database first, then commit it — the dictionary reflects what is in
the database.

## Developer checklist for a new or reworked module

1. In the SQL script, describe new tables and non-obvious columns:
   ```sql
   EXEC sys.sp_addextendedproperty 'MS_Description', N'What the table holds', 'SCHEMA', 'dbo', 'TABLE', 'MyTable';
   EXEC sys.sp_addextendedproperty 'MS_Description', N'P = paid, U = unpaid', 'SCHEMA', 'dbo', 'TABLE', 'MyTable', 'COLUMN', 'Status';
   ```
2. Declare foreign keys where possible; otherwise name reference columns after the parent key (`PatientId`,
   `LabOrderId` ...) so the relation is inferred, or add it to `ALIAS` / `CONTEXT_ALIAS` / `CONDITIONAL` in `dd_config.py`.
3. Put the new tables in their module in `dd_config.py` (`MODULES`); a brand-new module gets its own entry.
4. Apply the script, commit — the hook refreshes the document.
