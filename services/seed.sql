-- Demo customers for local runs (docker compose). Same accounts as the AWS database.
INSERT IGNORE INTO users (username, password, name, account, balance) VALUES
 ('akshata', 'demo123', 'Akshata Deshpande', 'ACC1001', 150000),
 ('rahul', 'demo123', 'Rahul Sharma', 'ACC1002', 30000),
 ('priya', 'demo123', 'Priya Patil', 'ACC1003', 75000);
