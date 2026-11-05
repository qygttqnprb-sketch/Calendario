create index invites_couple on private.invites(couple_id);
create index links_event on public.app_links(event_id);
create index requests_requester on public.completion_requests(requested_by);
create index participants_user on public.event_participants(user_id);
create index events_couple_owner on public.events(couple_id,owner_id);
create index events_owner on public.events(owner_id);
create index history_actor on public.obligation_history(actor_id);
create index slots_owner on public.obligation_slots(owner_id);
alter policy profile_read on public.profiles using(id=(select auth.uid()) or exists(select 1 from public.couple_members m where m.user_id=profiles.id and private.is_member(m.couple_id)));
alter policy events_read on public.events using(private.is_member(couple_id) and (owner_id=(select auth.uid()) or visibility='shared'));
-- Internal tables deliberately deny every direct client access.
create policy invites_deny_clients on private.invites to authenticated using(false) with check(false);
create policy week_runs_deny_clients on private.week_runs to authenticated using(false) with check(false);
