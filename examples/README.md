# Try CSV import

`transactions.csv` contains five fictional CAD purchases. You can import and
edit them without a model, bank connection, or iCloud folder. These records use
the app's normal database and persist after you quit.

1. Build the app using the [setup guide](../docs/setup.md).
2. In Settings, create a CAD account named `Demo account`. Choose Chequing as
   its kind. Select **Only when I click Process queue** if you want to keep
   classification under manual control.
3. Open Sync, choose **Import CSV**, and select `examples/transactions.csv`.
4. Use this mapping:

| Import setting | Value |
| --- | --- |
| Delimiter | Comma |
| Date | `date` |
| Description | `description` |
| Amount / debit | `amount` |
| Credit | None |
| Bank record ID | `record_id` |
| Account | Demo account |
| Date format | `yyyy-MM-dd` |
| Positive amounts mean spending | Off |
| Comma decimal separator | Off |

Choose **Validate rows**, then **Import selected rows**. The file contains five
outgoing transactions totaling CAD 78.73. Open Transactions, edit a record's
category, and save it. Quit and reopen the app to check that the edit persists.
Importing the same file into the same account again should add no records.

To try categorization, configure a provider and click **Process queue**. Review
each suggestion before confirming it. You can soft-delete the sample transactions
when you finish; their import history remains in the database.
