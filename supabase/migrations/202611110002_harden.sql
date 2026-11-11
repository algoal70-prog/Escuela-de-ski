alter function public.clock_text(int) set search_path=public;
create policy requests_deny_direct on public.requests for select to authenticated using(false);
