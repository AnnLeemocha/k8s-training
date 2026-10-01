-- 部署完成、initdb 跑完之後，「業務上」寫入的資料。
-- 這三筆不在 init SQL 裡 —— 只存在 PVC 上。還原後找不到它們 = 資料沒救回來。
INSERT INTO orders(order_no, note) VALUES
  ('ORDER-1001', '客戶 A 的訂單'),
  ('ORDER-1002', '客戶 B 的訂單'),
  ('ORDER-1003', '客戶 C 的訂單');
