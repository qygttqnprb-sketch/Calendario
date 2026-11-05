#!/usr/bin/env python3
"""Real Postgres integration tests; DATABASE_URL must identify a disposable database.
Uses auth.uid() fixtures to exercise the same authenticated role/RLS as PostgREST.
No production database must ever be used: fixtures create roles/auth schema.
"""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
A='10000000-0000-0000-0000-000000000001'
B='10000000-0000-0000-0000-000000000002'
C='10000000-0000-0000-0000-000000000003'

def sql(query, user=None, fail=False):
    prefix = f"set role authenticated; set request.jwt.claim.sub = '{user}';" if user else ''
    process = subprocess.run(['psql',os.environ['DATABASE_URL'],'-X','-qAt','-v','ON_ERROR_STOP=1','-c',prefix+query],text=True,capture_output=True)
    if fail:
        if process.returncode == 0: raise AssertionError('Operation should have failed: '+query)
        return process.stderr
    if process.returncode: raise AssertionError(process.stderr)
    return process.stdout.strip()

class DatabaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sql("""create role anon nologin; create role authenticated nologin;
        create schema auth; create table auth.users(id uuid primary key);
        create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
        grant usage on schema auth to authenticated;
        grant execute on function auth.uid() to authenticated;
        create publication supabase_realtime;
        """)
        sql((ROOT/'supabase/migrations/20261104000100_initial.sql').read_text())
        sql(f"insert into auth.users values ('{A}'),('{B}'),('{C}');")
        cls.couple=sql("select public.create_couple('Noi','Alice');",A)
        token=sql(f"select public.create_invite('{cls.couple}');",A)
        sql(f"select public.join_couple('{token}','Bob');",B)
        sql(f"select public.join_couple('{token}','Eve');",C,fail=True)
        cls.week=sql(f"select public.ensure_weekly_slots('{cls.couple}');",A)
        cls.shared=cls.event('shared','Cena insieme')
        cls.private=cls.event('private','SEGRETO')
        cls.busy=cls.event('busy_only','ALTRO SEGRETO')
    @classmethod
    def event(cls, visibility, title):
        return sql(f"select public.save_event('{cls.couple}','{title}',now(),now()+interval '1 hour','{visibility}',p_partner=>true);",A)
    def test_01_rls_third_account(self):
        for table in ['profiles','couples','couple_members','couple_settings','events','event_participants','obligation_slots','completion_requests','obligation_history','app_links','couple_changes']:
            self.assertEqual(sql(f'select count(*) from public.{table};',C),'0',table)
        sql(f"select public.calendar_events('{self.couple}',now()-interval '1 day',now()+interval '1 day');",C,fail=True)
        sql(f"select public.ensure_weekly_slots('{self.couple}');",C,fail=True)
    def test_02_privacy(self):
        self.assertEqual(sql(f"select count(*) from public.events where id in ('{self.private}','{self.busy}');",B),'0')
        result=sql(f"select title||'|'||description||'|'||location_text||'|'||coalesce(external_url,'') from public.calendar_events('{self.couple}',now()-interval '1 day',now()+interval '1 day');",B)
        self.assertIn('Cena insieme',result); self.assertIn('Occupato|||',result); self.assertNotIn('SEGRETO',result)
        self.assertEqual(sql(f"select count(*) from public.event_participants where event_id='{self.private}';",B),'0')
        sql(f"select public.save_event('{self.couple}','Hacked',now(),now()+interval '1 hour','shared',p_event_id=>'{self.shared}');",B,fail=True)
    def test_03_generation_concurrency(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: sql(f"select public.ensure_weekly_slots('{self.couple}');",A),range(8)))
        self.assertEqual(sql(f"select count(*) from public.obligation_slots where origin_week_start='{self.week}';",A),'4')
        self.assertEqual(sql("select string_agg(n::text,',') from (select count(*) n from public.obligation_slots group by owner_id) s;",A),'2,2')
        sql(f"select public.ensure_weekly_slots('{self.couple}','2000-01-03');",A,fail=True)
    def test_04_owner_and_review_transitions(self):
        slot=sql(f"select id from public.obligation_slots where owner_id='{A}' order by slot_index limit 1;",A)
        sql(f"select public.assign_obligation('{slot}','{self.shared}','couple');",B,fail=True)
        sql(f"select public.assign_obligation('{slot}','{self.shared}','couple');",A)
        req=sql(f"select public.request_completion('{slot}','Finito');",A)
        sql(f"select public.review_completion('{req}',true);",A,fail=True)
        sql(f"select public.review_completion('{req}',true);",C,fail=True)
        sql(f"select public.request_completion('{slot}');",A,fail=True)
        self.assertEqual(sql(f"select status from public.obligation_slots where id='{slot}';",A),'pending_confirmation')
        sql(f"select public.review_completion('{req}',false,'Riproviamo');",B)
        self.assertEqual(sql(f"select status||'|'||(completed_at is null)::text from public.obligation_slots where id='{slot}';",A),'disputed|true')
        req=sql(f"select public.request_completion('{slot}');",A)
        def compete(_):
            try: sql(f"select public.review_completion('{req}',true);",B); return True
            except AssertionError: return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(compete,range(2)))
        self.assertEqual(sum(results),1)
        self.assertEqual(sql(f"select status from public.obligation_slots where id='{slot}';",A),'completed')
        self.assertEqual(sql(f"select count(*) from public.obligation_history where obligation_id='{slot}' and action='approved';",A),'1')
        sql(f"select public.save_event('{self.couple}','Changed',now(),now()+interval '1 hour','shared',p_event_id=>'{self.shared}');",A,fail=True)
    def test_05_carryover_is_same_row(self):
        old=sql(f"insert into public.obligation_slots(couple_id,owner_id,origin_week_start,slot_index) values('{self.couple}','{A}','{self.week}'::date-7,1) returning id;")
        sql(f"select public.ensure_weekly_slots('{self.couple}');",A)
        self.assertEqual(sql(f"select count(*) from public.obligation_slots where id='{old}' and origin_week_start<'{self.week}' and status<>'completed';",A),'1')
        self.assertEqual(sql(f"select count(*) from public.obligation_slots where origin_week_start='{self.week}';",A),'4')
    def test_06_no_direct_writes_or_internal_rpc(self):
        for query in ["update public.obligation_slots set status='completed';", "delete from public.couple_members;", "update public.events set visibility='shared';", "select private.generate_all_current_weeks();", "select private.generate_week(null,current_date);", "select * from private.invites;"]:
            sql(query,A,fail=True)
        self.assertEqual(sql("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','private') and c.relkind='r' and not c.relrowsecurity;"),'0')
    def test_07_timezone_dst_year_boundary(self):
        self.assertEqual(sql("select date_trunc('week','2026-11-01 23:30+00'::timestamptz at time zone 'Europe/Rome')::date;"),'2026-11-02')
        self.assertEqual(sql("select date_trunc('week','2027-01-01 12:00+00'::timestamptz at time zone 'Europe/Rome')::date;"),'2026-12-28')
        self.assertEqual(sql("select extract(epoch from ('2026-03-30 00:00'::timestamp at time zone 'Europe/Rome')-('2026-03-23 00:00'::timestamp at time zone 'Europe/Rome'))::int/3600;"),'167')
        sql(f"select public.update_settings('{self.couple}','Invalid/Zone',2);",A,fail=True)
    def test_08_quota_snapshot(self):
        sql(f"select public.update_settings('{self.couple}','Europe/Rome',3);",A)
        sql(f"select public.ensure_weekly_slots('{self.couple}');",A)
        self.assertEqual(sql(f"select count(*) from public.obligation_slots where origin_week_start='{self.week}';",A),'4')
    def test_09_https(self):
        for url in ['http://example.com','javascript:alert(1)','https://user:pass@example.com','https://example.com:666/']:
            sql(f"select public.save_event('{self.couple}','URL',now(),now()+interval '1 hour','shared',p_url=>'{url}');",A,fail=True)
    def test_10_full_couple_and_expired_invite(self):
        sql(f"select public.create_invite('{self.couple}');",A,fail=True)
        second=sql("select public.create_couple('Altra','Eve');",C)
        token=sql(f"select public.create_invite('{second}');",C)
        sql(f"update private.invites set expires_at=now()-interval '1 second' where couple_id='{second}';")
        sql(f"select public.join_couple('{token}','Alice');",A,fail=True)

if __name__=='__main__':
    if not os.environ.get('DATABASE_URL'): sys.exit('Set DATABASE_URL to a disposable empty PostgreSQL database. Never use production.')
    unittest.main(verbosity=2)
