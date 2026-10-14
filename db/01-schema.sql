-- Jamii Savings - core accounts schema (MySQL 8.x)
-- Loaded automatically by the mysql container from /docker-entrypoint-initdb.d

CREATE DATABASE IF NOT EXISTS jamii_core
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

USE jamii_core;

-- customer_id deliberately matches the DummyJSON /users/{id} ids used by the
-- customer proxy (1b), so the dashboard aggregation (bonus A) can join them.
CREATE TABLE IF NOT EXISTS accounts (
  account_number CHAR(10)       NOT NULL,
  customer_id    INT UNSIGNED   NOT NULL,
  account_type   VARCHAR(20)    NOT NULL,
  status         ENUM('ACTIVE','DORMANT','CLOSED') NOT NULL,
  balance        DECIMAL(18,2)  NOT NULL DEFAULT 0.00,
  currency       CHAR(3)        NOT NULL DEFAULT 'KES',
  opened_on      DATE           NOT NULL,
  updated_at     TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (account_number),
  KEY idx_accounts_customer (customer_id),
  CONSTRAINT chk_account_number CHECK (account_number REGEXP '^[0-9]{10}$'),
  CONSTRAINT chk_currency       CHECK (currency REGEXP '^[A-Z]{3}$')
) ENGINE=InnoDB;

-- Least-privilege runtime user for the MI data service: read-only on accounts.
CREATE USER IF NOT EXISTS 'jamii_mi'@'%' IDENTIFIED BY 'jamii_mi_pw';
GRANT SELECT ON jamii_core.accounts TO 'jamii_mi'@'%';
FLUSH PRIVILEGES;
