-- Safe smoke test on staging/hosted Supabase: fixtures exist only within a rollback.
-- Run as an administrator. No email is sent, no password or persistent user is created.
begin;
insert into auth.users(id) values
 ('20000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002'),
 ('20000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
select set_config('coppia.test_couple', public.create_couple('Acceptance test','Alice')::text,true);
select set_config('coppia.test_invite',public.create_invite(current_setting('coppia.test_couple')::uuid),true);
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',true);
select public.join_couple(current_setting('coppia.test_invite'),'Bob');
select public.ensure_weekly_slots(current_setting('coppia.test_couple')::uuid);
select public.ensure_weekly_slots(current_setting('coppia.test_couple')::uuid);
do $$ begin
 if (select count(*) from public.obligation_slots where couple_id=current_setting('coppia.test_couple')::uuid)<>4 then raise exception 'Expected exactly four slots'; end if;
end $$;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
select set_config('coppia.test_shared',public.save_event(current_setting('coppia.test_couple')::uuid,'Shared',now(),now()+interval '1 hour','shared',p_partner=>true)::text,true);
select public.save_event(current_setting('coppia.test_couple')::uuid,'PRIVATE TITLE',now(),now()+interval '1 hour','private');
select public.save_event(current_setting('coppia.test_couple')::uuid,'BUSY SECRET',now(),now()+interval '1 hour','busy_only',p_description=>'HIDDEN',p_location=>'HIDDEN',p_url=>'https://example.com/private');
select set_config('coppia.test_slot',(select id::text from public.obligation_slots where couple_id=current_setting('coppia.test_couple')::uuid and owner_id=auth.uid() order by slot_index limit 1),true);
select public.assign_obligation(current_setting('coppia.test_slot')::uuid,current_setting('coppia.test_shared')::uuid,'couple');
select set_config('coppia.test_request',public.request_completion(current_setting('coppia.test_slot')::uuid)::text,true);
do $$ begin
 begin
   perform public.review_completion(current_setting('coppia.test_request')::uuid,true);
   raise exception 'Self approval must fail';
 exception when insufficient_privilege then null;
 end;
end $$;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',true);
do $$ declare records jsonb; begin
 if (select count(*) from public.events where couple_id=current_setting('coppia.test_couple')::uuid)<>1 then raise exception 'Private or busy event details visible through table'; end if;
 select jsonb_agg(to_jsonb(e)) into records from public.calendar_events(current_setting('coppia.test_couple')::uuid,now()-interval '1 day',now()+interval '1 day') e;
 if jsonb_array_length(records)<>2 or records::text like '%SECRET%' or records::text like '%PRIVATE TITLE%' or records::text like '%HIDDEN%' or records::text like '%example.com%' then raise exception 'Calendar privacy violation'; end if;
end $$;
select public.review_completion(current_setting('coppia.test_request')::uuid,false,'Try again');
do $$ begin
 if (select status from public.obligation_slots where id=current_setting('coppia.test_slot')::uuid)<>'disputed' then raise exception 'Rejection must remain open'; end if;
end $$;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
select set_config('coppia.test_request',public.request_completion(current_setting('coppia.test_slot')::uuid)::text,true);
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',true);
select public.review_completion(current_setting('coppia.test_request')::uuid,true);
do $$ begin
 if (select status from public.obligation_slots where id=current_setting('coppia.test_slot')::uuid)<>'completed' then raise exception 'Approval not committed'; end if;
 if (select count(*) from public.obligation_history where obligation_id=current_setting('coppia.test_slot')::uuid and action='approved')<>1 then raise exception 'Missing audit'; end if;
end $$;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000003',true);
do $$ begin
 if exists(select 1 from public.events) or exists(select 1 from public.obligation_slots) or exists(select 1 from public.couple_changes) then raise exception 'Third account can read another couple'; end if;
end $$;
reset role;
-- Exercise the exact entry point used by pg_cron, twice, including backlog.
insert into public.obligation_slots(couple_id,owner_id,origin_week_start,slot_index)
 values(current_setting('coppia.test_couple')::uuid,'20000000-0000-0000-0000-000000000001',private.current_week(current_setting('coppia.test_couple')::uuid)-7,1);
select private.generate_all_current_weeks();
select private.generate_all_current_weeks();
do $$ begin
 if (select count(*) from public.obligation_slots where couple_id=current_setting('coppia.test_couple')::uuid)<>5 then raise exception 'Scheduler duplicated slots or backlog'; end if;
end $$;
rollback;
select 'acceptance_passed_and_fixtures_rolled_back' as result;
