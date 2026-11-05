-- MVP v1. Mutations are authenticated RPCs; clients have read-only table grants.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;
create type public.event_visibility as enum ('private','shared','busy_only');
create type public.participant_response as enum ('pending','accepted','declined');
create type public.obligation_kind as enum ('personal','couple');
create type public.obligation_status as enum ('empty','scheduled','pending_confirmation','completed','disputed');
create type public.request_status as enum ('pending','approved','rejected');
create table public.profiles(id uuid primary key references auth.users on delete cascade, display_name text not null check(length(display_name) between 1 and 80), created_at timestamptz not null default now());
create table public.couples(id uuid primary key default gen_random_uuid(), name text not null check(length(name) between 1 and 100), timezone text not null default 'Europe/Rome', created_at timestamptz not null default now());
create table public.couple_members(couple_id uuid not null references public.couples, user_id uuid not null references public.profiles, role text not null default 'member' check(role in ('creator','member')), joined_at timestamptz not null default now(), primary key(couple_id,user_id), unique(user_id));
create table public.couple_settings(couple_id uuid primary key references public.couples, weekly_quota_per_person int not null default 2 check(weekly_quota_per_person between 1 and 10), week_start int not null default 1 check(week_start=1), carry_over boolean not null default true check(carry_over), mutual_confirmation boolean not null default true check(mutual_confirmation));
create table public.events(id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples, owner_id uuid not null references public.profiles, title text not null check(length(title) between 1 and 200), description text not null default '' check(length(description)<=5000), starts_at timestamptz not null, ends_at timestamptz not null, timezone text not null default 'Europe/Rome', visibility public.event_visibility not null default 'shared', location_text text not null default '', external_url text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), check(ends_at>starts_at), foreign key(couple_id,owner_id) references public.couple_members(couple_id,user_id));
create index events_calendar on public.events(couple_id,starts_at);
create table public.event_participants(event_id uuid not null references public.events on delete cascade, user_id uuid not null references public.profiles, response public.participant_response not null default 'pending', primary key(event_id,user_id));
create table public.obligation_slots(id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples, owner_id uuid not null references public.profiles, origin_week_start date not null check(extract(isodow from origin_week_start)=1), slot_index int not null check(slot_index between 1 and 10), event_id uuid references public.events, kind public.obligation_kind, status public.obligation_status not null default 'empty', completed_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(couple_id,owner_id,origin_week_start,slot_index), foreign key(couple_id,owner_id) references public.couple_members(couple_id,user_id), check((status='completed')=(completed_at is not null)));
create unique index one_event_per_obligation on public.obligation_slots(event_id) where event_id is not null;
create index slots_open on public.obligation_slots(couple_id,origin_week_start) where status <> 'completed';
create table public.completion_requests(id uuid primary key default gen_random_uuid(), obligation_id uuid not null references public.obligation_slots, requested_by uuid not null references public.profiles, reviewer_id uuid not null references public.profiles, status public.request_status not null default 'pending', note text not null default '' check(length(note)<=2000), requested_at timestamptz not null default now(), reviewed_at timestamptz, check(requested_by<>reviewer_id), check((status='pending')=(reviewed_at is null)));
create unique index one_pending_request on public.completion_requests(obligation_id) where status='pending';
create index requests_reviewer on public.completion_requests(reviewer_id,status);
create table public.obligation_history(id uuid primary key default gen_random_uuid(), obligation_id uuid not null references public.obligation_slots, actor_id uuid not null references public.profiles, action text not null, details jsonb not null default '{}', created_at timestamptz not null default now());
create index history_obligation on public.obligation_history(obligation_id);
create table public.app_links(id uuid primary key default gen_random_uuid(), event_id uuid not null references public.events on delete cascade, provider text not null, url text not null, metadata jsonb not null default '{}');
-- No event titles/IDs/notes in this invalidation channel. Updates only, no deletes.
create table public.couple_changes(couple_id uuid primary key references public.couples, revision bigint not null default 0);
create table private.invites(token_hash text primary key, couple_id uuid not null references public.couples, expires_at timestamptz not null, used_at timestamptz);
create table private.week_runs(couple_id uuid not null references public.couples, week_start date not null, quota int not null, primary key(couple_id,week_start));
alter table private.invites enable row level security;
alter table private.week_runs enable row level security;

create function private.is_member(c uuid) returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.couple_members where couple_id=c and user_id=(select auth.uid())) $$;
create function private.require_member(c uuid) returns void language plpgsql security definer set search_path='' as $$ begin if auth.uid() is null or not private.is_member(c) then raise exception 'Not a couple member' using errcode='42501'; end if; end $$;
create function private.touch(c uuid) returns void language sql security definer set search_path='' as $$ update public.couple_changes set revision=revision+1 where couple_id=c $$;
create function private.valid_timezone(t text) returns boolean language sql stable set search_path='' as $$ select exists(select 1 from pg_catalog.pg_timezone_names where name=t) $$;
-- Parse a conservative HTTPS authority. No credentials, ports, IPs or ambiguous hosts.
create function private.valid_link(u text) returns boolean language sql immutable set search_path='' as $$ select u is null or (length(u)<=2048 and u ~ '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}([/?#][^[:space:]\\]*)?$' and u !~ '[[:cntrl:]]') $$;
alter table public.events add constraint event_link_safe check(private.valid_link(external_url));
alter table public.app_links add constraint app_link_safe check(private.valid_link(url));
create function private.guard_members() returns trigger language plpgsql security definer set search_path='' as $$ begin perform 1 from public.couples where id=new.couple_id for update; if (select count(*) from public.couple_members where couple_id=new.couple_id)>=2 then raise exception 'Couple already full'; end if; return new; end $$;
create trigger maximum_two before insert on public.couple_members for each row execute function private.guard_members();

-- RLS: no direct client writes. Private/busy event records are never selectable by partner.
alter table public.profiles enable row level security;
create policy profile_read on public.profiles for select to authenticated using(id=auth.uid() or exists(select 1 from public.couple_members m where m.user_id=profiles.id and private.is_member(m.couple_id)));
alter table public.couples enable row level security;
create policy couple_read on public.couples for select to authenticated using(private.is_member(id));
alter table public.couple_members enable row level security;
create policy members_read on public.couple_members for select to authenticated using(private.is_member(couple_id));
alter table public.couple_settings enable row level security;
create policy settings_read on public.couple_settings for select to authenticated using(private.is_member(couple_id));
alter table public.events enable row level security;
create policy events_read on public.events for select to authenticated using(private.is_member(couple_id) and (owner_id=auth.uid() or visibility='shared'));
alter table public.event_participants enable row level security;
create policy participants_read on public.event_participants for select to authenticated using(exists(select 1 from public.events e where e.id=event_id));
alter table public.obligation_slots enable row level security;
create policy slots_read on public.obligation_slots for select to authenticated using(private.is_member(couple_id));
alter table public.completion_requests enable row level security;
create policy requests_read on public.completion_requests for select to authenticated using(exists(select 1 from public.obligation_slots s where s.id=obligation_id and private.is_member(s.couple_id)));
alter table public.obligation_history enable row level security;
create policy history_read on public.obligation_history for select to authenticated using(exists(select 1 from public.obligation_slots s where s.id=obligation_id and private.is_member(s.couple_id)));
alter table public.app_links enable row level security;
create policy links_read on public.app_links for select to authenticated using(exists(select 1 from public.events e where e.id=event_id));
alter table public.couple_changes enable row level security;
create policy changes_read on public.couple_changes for select to authenticated using(private.is_member(couple_id));

create function private.create_couple(p_name text,p_display_name text) returns uuid language plpgsql security definer set search_path='' as $$ declare c uuid; begin
 if auth.uid() is null then raise exception 'Login required' using errcode='42501'; end if;
 insert into public.profiles(id,display_name) values(auth.uid(),p_display_name) on conflict(id) do update set display_name=excluded.display_name;
 insert into public.couples(name) values(p_name) returning id into c;
 insert into public.couple_members(couple_id,user_id,role) values(c,auth.uid(),'creator');
 insert into public.couple_settings(couple_id) values(c); insert into public.couple_changes(couple_id) values(c); return c; end $$;
create function private.create_invite(p_couple_id uuid) returns text language plpgsql security definer set search_path='' as $$ declare token text; begin
 perform private.require_member(p_couple_id); perform 1 from public.couples where id=p_couple_id for update;
 if (select count(*) from public.couple_members where couple_id=p_couple_id)>=2 then raise exception 'Couple already full'; end if;
 token:=replace(gen_random_uuid()::text,'-','');
 update private.invites set used_at=now() where couple_id=p_couple_id and used_at is null;
 insert into private.invites values(encode(sha256(convert_to(token,'UTF8')),'hex'),p_couple_id,now()+interval '24 hours',null); return token; end $$;
create function private.join_couple(p_code text,p_display_name text) returns uuid language plpgsql security definer set search_path='' as $$ declare i private.invites; begin
 if auth.uid() is null then raise exception 'Login required' using errcode='42501'; end if;
 select * into i from private.invites where token_hash=encode(sha256(convert_to(trim(p_code),'UTF8')),'hex') for update;
 if not found or i.used_at is not null or i.expires_at<=now() then raise exception 'Invalid or expired invitation'; end if;
 insert into public.profiles(id,display_name) values(auth.uid(),p_display_name) on conflict(id) do update set display_name=excluded.display_name;
 insert into public.couple_members(couple_id,user_id) values(i.couple_id,auth.uid());
 update private.invites set used_at=now() where token_hash=i.token_hash; perform private.touch(i.couple_id); return i.couple_id; end $$;
create function private.current_week(c uuid) returns date language sql stable security definer set search_path='' as $$ select date_trunc('week',now() at time zone timezone)::date from public.couples where id=c $$;
create function private.generate_week(c uuid,w date) returns void language plpgsql security definer set search_path='' as $$ declare q int; inserted int; begin
 perform 1 from public.couples where id=c for update;
 insert into private.week_runs select c,w,weekly_quota_per_person from public.couple_settings where couple_id=c on conflict do nothing;
 select quota into q from private.week_runs where couple_id=c and week_start=w;
 insert into public.obligation_slots(couple_id,owner_id,origin_week_start,slot_index)
 select c,user_id,w,n from public.couple_members cross join generate_series(1,q) n where couple_id=c on conflict do nothing;
 get diagnostics inserted = row_count; if inserted>0 then perform private.touch(c); end if;
 end $$;
create function private.ensure_weekly_slots(p_couple_id uuid,p_week_start date default null) returns date language plpgsql security definer set search_path='' as $$ declare w date; begin
 perform private.require_member(p_couple_id); w:=private.current_week(p_couple_id);
 if p_week_start is not null and p_week_start<>w then raise exception 'Only current local ISO week can be generated'; end if;
 perform private.generate_week(p_couple_id,w); return w; end $$;
-- Intended only for the database scheduler; never granted to clients.
create function private.generate_all_current_weeks() returns void language plpgsql security definer set search_path='' as $$ declare c uuid; begin for c in select id from public.couples loop perform private.generate_week(c,private.current_week(c)); end loop; end $$;

create function private.save_event(p_couple_id uuid,p_title text,p_starts_at timestamptz,p_ends_at timestamptz,p_visibility public.event_visibility,p_description text default '',p_location text default '',p_url text default null,p_partner boolean default false,p_event_id uuid default null) returns uuid language plpgsql security definer set search_path='' as $$ declare e public.events; eid uuid; z text; begin
 perform private.require_member(p_couple_id); select timezone into z from public.couples where id=p_couple_id;
 if p_event_id is not null then
 select * into e from public.events where id=p_event_id for update;
 if not found or e.owner_id<>auth.uid() or e.couple_id<>p_couple_id then raise exception 'Only owner can edit' using errcode='42501'; end if;
 if exists(select 1 from public.obligation_slots where event_id=e.id and status in ('pending_confirmation','completed')) then raise exception 'Event locked by completion'; end if;
 update public.events set title=p_title,description=p_description,starts_at=p_starts_at,ends_at=p_ends_at,visibility=p_visibility,location_text=p_location,external_url=nullif(p_url,''),updated_at=now() where id=e.id; eid:=e.id;
 else
 insert into public.events(couple_id,owner_id,title,description,starts_at,ends_at,timezone,visibility,location_text,external_url) values(p_couple_id,auth.uid(),p_title,p_description,p_starts_at,p_ends_at,z,p_visibility,p_location,nullif(p_url,'')) returning id into eid;
 end if;
 delete from public.app_links where event_id=eid;
 if nullif(p_url,'') is not null then
 insert into public.app_links(event_id,provider,url) values(eid,
 case when p_url ~ '^https://(www[.])?thefork[.]' then 'thefork'
 when p_url ~ '^https://(www[.])?toogoodtogo[.]' then 'too_good_to_go'
 when p_url ~ '^https://(maps[.]apple[.]com|maps[.]google[.]com)/' then 'maps'
 else 'https' end,p_url);
 end if;
 delete from public.event_participants where event_id=eid;
 insert into public.event_participants(event_id,user_id,response) values(eid,auth.uid(),'accepted');
 if p_partner and p_visibility='shared' then insert into public.event_participants(event_id,user_id) select eid,user_id from public.couple_members where couple_id=p_couple_id and user_id<>auth.uid(); end if;
 perform private.touch(p_couple_id); return eid; end $$;
create function private.calendar_events(p_couple_id uuid,p_from timestamptz,p_to timestamptz) returns table(id uuid,owner_id uuid,title text,description text,starts_at timestamptz,ends_at timestamptz,timezone text,visibility public.event_visibility,location_text text,external_url text) language plpgsql stable security definer set search_path='' as $$ begin
 perform private.require_member(p_couple_id);
 return query select e.id,e.owner_id,case when e.owner_id=auth.uid() or e.visibility='shared' then e.title else 'Occupato' end,case when e.owner_id=auth.uid() or e.visibility='shared' then e.description else '' end,e.starts_at,e.ends_at,e.timezone,e.visibility,case when e.owner_id=auth.uid() or e.visibility='shared' then e.location_text else '' end,case when e.owner_id=auth.uid() or e.visibility='shared' then e.external_url else null end from public.events e where e.couple_id=p_couple_id and e.starts_at<p_to and e.ends_at>p_from and (e.owner_id=auth.uid() or e.visibility<>'private'); end $$;
create function private.assign_obligation(p_obligation_id uuid,p_event_id uuid,p_kind public.obligation_kind) returns void language plpgsql security definer set search_path='' as $$ declare s public.obligation_slots; e public.events; begin
 select * into s from public.obligation_slots where id=p_obligation_id for update; perform private.require_member(s.couple_id);
 if s.owner_id<>auth.uid() then raise exception 'Only owner can assign' using errcode='42501'; end if;
 if s.status not in ('empty','scheduled','disputed') then raise exception 'Obligation locked'; end if;
 select * into e from public.events where id=p_event_id for update;
 if not found or e.owner_id<>auth.uid() or e.couple_id<>s.couple_id or p_kind is null then raise exception 'Invalid event'; end if;
 if p_kind='couple' and (e.visibility<>'shared' or (select count(*) from public.event_participants where event_id=e.id)<>2) then raise exception 'Couple event requires both participants and shared visibility'; end if;
 update public.obligation_slots set event_id=e.id,kind=p_kind,status='scheduled',updated_at=now() where id=s.id;
 insert into public.obligation_history(obligation_id,actor_id,action) values(s.id,auth.uid(),'assigned'); perform private.touch(s.couple_id); end $$;
create function private.request_completion(p_obligation_id uuid,p_note text default '') returns uuid language plpgsql security definer set search_path='' as $$ declare s public.obligation_slots; reviewer uuid; r uuid; begin
 select * into s from public.obligation_slots where id=p_obligation_id for update; perform private.require_member(s.couple_id);
 if s.owner_id<>auth.uid() then raise exception 'Only owner can request' using errcode='42501'; end if;
 perform 1 from public.events where id=s.event_id for update;
 if s.status not in ('scheduled','disputed') or s.event_id is null then raise exception 'Invalid transition'; end if;
 select user_id into reviewer from public.couple_members where couple_id=s.couple_id and user_id<>auth.uid();
 if reviewer is null then raise exception 'Partner required'; end if;
 insert into public.completion_requests(obligation_id,requested_by,reviewer_id,note) values(s.id,auth.uid(),reviewer,p_note) returning id into r;
 update public.obligation_slots set status='pending_confirmation',updated_at=now() where id=s.id;
 insert into public.obligation_history(obligation_id,actor_id,action) values(s.id,auth.uid(),'confirmation_requested'); perform private.touch(s.couple_id); return r; end $$;
create function private.review_completion(p_request_id uuid,p_approve boolean,p_note text default '') returns void language plpgsql security definer set search_path='' as $$ declare r public.completion_requests; s public.obligation_slots; oid uuid; begin
 select obligation_id into oid from public.completion_requests where id=p_request_id;
 select * into s from public.obligation_slots where id=oid for update;
 select * into r from public.completion_requests where id=p_request_id for update; perform private.require_member(s.couple_id);
 if r.reviewer_id<>auth.uid() or r.requested_by=auth.uid() then raise exception 'Only partner reviewer can review' using errcode='42501'; end if;
 if r.status<>'pending' or s.status<>'pending_confirmation' or p_approve is null then raise exception 'Already reviewed or invalid transition'; end if;
 update public.completion_requests set status=case when p_approve then 'approved'::public.request_status else 'rejected'::public.request_status end,reviewed_at=now() where id=r.id;
 update public.obligation_slots set status=case when p_approve then 'completed'::public.obligation_status else 'disputed'::public.obligation_status end,completed_at=case when p_approve then now() else null end,updated_at=now() where id=s.id;
 insert into public.obligation_history(obligation_id,actor_id,action,details) values(s.id,auth.uid(),case when p_approve then 'approved' else 'disputed' end,jsonb_build_object('request_id',r.id,'note',left(p_note,2000))); perform private.touch(s.couple_id); end $$;
create function private.update_settings(p_couple_id uuid,p_timezone text,p_quota int) returns void language plpgsql security definer set search_path='' as $$ begin
 perform private.require_member(p_couple_id); if not private.valid_timezone(p_timezone) then raise exception 'Invalid timezone'; end if;
 perform 1 from public.couples where id=p_couple_id for update;
 update public.couples set timezone=p_timezone where id=p_couple_id;
 update public.couple_settings set weekly_quota_per_person=p_quota where couple_id=p_couple_id; perform private.touch(p_couple_id); end $$;

-- Public invoker wrappers expose only reviewed RPCs. Private helpers remain uncallable.
create function public.create_couple(p_name text,p_display_name text) returns uuid language sql security invoker set search_path='' as $$ select * from private.create_couple(p_name,p_display_name) $$;
create function public.create_invite(p_couple_id uuid) returns text language sql security invoker set search_path='' as $$ select * from private.create_invite(p_couple_id) $$;
create function public.join_couple(p_code text,p_display_name text) returns uuid language sql security invoker set search_path='' as $$ select * from private.join_couple(p_code,p_display_name) $$;
create function public.ensure_weekly_slots(p_couple_id uuid,p_week_start date default null) returns date language sql security invoker set search_path='' as $$ select * from private.ensure_weekly_slots(p_couple_id,p_week_start) $$;
create function public.save_event(p_couple_id uuid,p_title text,p_starts_at timestamptz,p_ends_at timestamptz,p_visibility public.event_visibility,p_description text default '',p_location text default '',p_url text default null,p_partner boolean default false,p_event_id uuid default null) returns uuid language sql security invoker set search_path='' as $$ select * from private.save_event(p_couple_id,p_title,p_starts_at,p_ends_at,p_visibility,p_description,p_location,p_url,p_partner,p_event_id) $$;
create function public.calendar_events(p_couple_id uuid,p_from timestamptz,p_to timestamptz) returns table(id uuid,owner_id uuid,title text,description text,starts_at timestamptz,ends_at timestamptz,timezone text,visibility public.event_visibility,location_text text,external_url text) language sql security invoker set search_path='' as $$ select * from private.calendar_events(p_couple_id,p_from,p_to) $$;
create function public.assign_obligation(p_obligation_id uuid,p_event_id uuid,p_kind public.obligation_kind) returns void language sql security invoker set search_path='' as $$ select * from private.assign_obligation(p_obligation_id,p_event_id,p_kind) $$;
create function public.request_completion(p_obligation_id uuid,p_note text default '') returns uuid language sql security invoker set search_path='' as $$ select * from private.request_completion(p_obligation_id,p_note) $$;
create function public.review_completion(p_request_id uuid,p_approve boolean,p_note text default '') returns void language sql security invoker set search_path='' as $$ select * from private.review_completion(p_request_id,p_approve,p_note) $$;
create function public.update_settings(p_couple_id uuid,p_timezone text,p_quota int) returns void language sql security invoker set search_path='' as $$ select * from private.update_settings(p_couple_id,p_timezone,p_quota) $$;
revoke all on all functions in schema private from public,anon,authenticated;
revoke all on all functions in schema public from public,anon,authenticated;
revoke all on all tables in schema public from anon,authenticated;
grant select on all tables in schema public to authenticated;
grant execute on function public.create_couple(text,text), private.create_couple(text,text) to authenticated;
grant execute on function public.create_invite(uuid), private.create_invite(uuid) to authenticated;
grant execute on function public.join_couple(text,text), private.join_couple(text,text) to authenticated;
grant execute on function public.ensure_weekly_slots(uuid,date), private.ensure_weekly_slots(uuid,date) to authenticated;
grant execute on function public.save_event(uuid,text,timestamptz,timestamptz,public.event_visibility,text,text,text,boolean,uuid), private.save_event(uuid,text,timestamptz,timestamptz,public.event_visibility,text,text,text,boolean,uuid) to authenticated;
grant execute on function public.calendar_events(uuid,timestamptz,timestamptz), private.calendar_events(uuid,timestamptz,timestamptz) to authenticated;
grant execute on function public.assign_obligation(uuid,uuid,public.obligation_kind), private.assign_obligation(uuid,uuid,public.obligation_kind) to authenticated;
grant execute on function public.request_completion(uuid,text), private.request_completion(uuid,text) to authenticated;
grant execute on function public.review_completion(uuid,boolean,text), private.review_completion(uuid,boolean,text) to authenticated;
grant execute on function public.update_settings(uuid,text,int), private.update_settings(uuid,text,int) to authenticated;
grant execute on function private.is_member(uuid),private.valid_link(text) to authenticated;
alter publication supabase_realtime add table public.couple_changes;
