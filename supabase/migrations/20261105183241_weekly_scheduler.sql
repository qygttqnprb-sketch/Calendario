-- Supabase supports pg_cron. No service-role key or external scheduler required.
create extension if not exists pg_cron;
select cron.schedule('coppia-weekly-slots','* * * * *',
  $$select private.generate_all_current_weeks()$$);
