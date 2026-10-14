USE jamii_core;

-- Test data. Account numbers are 10 digits; none start with 0.
INSERT INTO accounts (account_number, customer_id, account_type, status, balance, currency, opened_on) VALUES
  ('1000000001', 1, 'SAVINGS', 'ACTIVE',   152340.75, 'KES', '2019-03-14'),
  ('1000000002', 1, 'CURRENT', 'ACTIVE',     8420.00, 'KES', '2021-07-01'),
  ('1000000003', 2, 'SAVINGS', 'DORMANT',     310.50, 'KES', '2016-11-20'),
  ('1000000004', 3, 'SAVINGS', 'CLOSED',        0.00, 'KES', '2015-01-09'),
  ('1000000005', 3, 'FIXED',   'ACTIVE',  1250000.00, 'KES', '2023-02-28'),
  ('1000000006', 4, 'SAVINGS', 'ACTIVE',     4999.99, 'USD', '2022-09-12'),
  ('1000000007', 5, 'CURRENT', 'ACTIVE',       12.05, 'KES', '2024-05-30')
ON DUPLICATE KEY UPDATE balance = VALUES(balance), status = VALUES(status);
