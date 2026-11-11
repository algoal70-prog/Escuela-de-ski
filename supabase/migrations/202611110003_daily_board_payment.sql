-- A computed operational flag: the database clock decides the cutoff, without a cron.
create view public.class_board with (security_invoker=true) as
select c.*, (c.type='grupal' and c.status not in ('dictada','cancelada')
 and now()>=((c.day-1)+time '18:00') at time zone 'America/Argentina/Buenos_Aires'
 and (select count(*) from public.enrollments en where en.class_id=c.id and en.status='confirmada')<3) as needs_review
from public.classes c;
revoke all on public.class_board from anon,authenticated;
grant select on public.class_board to authenticated;
-- Reception gets payment status only, never the private financial row.
create function public.payment_states(d date) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if not is_staff() then raise exception 'No tenés permiso para consultar cobros.';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('class_id',c.id,'payment',f.payment)),'[]') from classes c join finances f on f.class_id=c.id where c.day=d);
end $$;
revoke all on function public.payment_states(date) from public,anon,authenticated;
grant execute on function public.payment_states(date) to authenticated;
create index classes_day_instructor on public.classes(day,instructor_id);
create index classes_day_sector on public.classes(day,sector_id);
create index enrollments_class_status on public.enrollments(class_id,status,created_at);
create index enrollments_student on public.enrollments(student_id);
create index rentals_product_day on public.rentals(product_id,day) where status='reservado';
create index rentals_student on public.rentals(student_id);
create index rentals_class on public.rentals(class_id);
create index availability_instructor_day on public.availability(instructor_id,day);
create index closures_sector_day on public.closures(sector_id,day);
