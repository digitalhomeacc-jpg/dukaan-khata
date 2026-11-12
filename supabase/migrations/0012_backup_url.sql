-- Link to the shop's Google Drive backup script (the "Backup now" button).
alter table businesses add column if not exists backup_url text;
