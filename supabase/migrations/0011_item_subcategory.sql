-- Optional subcategory for items (प्लंबिंग → टाकी, पाईप, लिक्विड …).
alter table items add column if not exists subcategory text;
