-- COTA: all exposed tables use RLS. Mutations only through atomic RPCs.
create table public.profiles(id uuid primary key references auth.users(id) on delete cascade, name text not null, role text not null check(role in ('coordinacion','recepcion','instructor')));
create function public.app_role() returns text language sql stable security definer set search_path=public as $$ select role from profiles where id=auth.uid() $$;
create function public.is_staff() returns boolean language sql stable security definer set search_path=public as $$ select coalesce(app_role() in ('coordinacion','recepcion'),false) $$;
create table public.instructors(id uuid primary key default gen_random_uuid(), profile_id uuid unique references profiles, name text not null, disciplines text[] not null, max_level int check(max_level between 1 and 4), languages text[] not null default '{es}', max_hours numeric not null default 6, days_off int[] not null default '{}');
create table public.sectors(id uuid primary key default gen_random_uuid(), name text unique not null, levels int[] not null, capacity int not null check(capacity>0), indoor boolean default false, wind_sensitive boolean default false);
create table public.students(id uuid primary key default gen_random_uuid(), name text not null, birth_date date not null, phone text not null default '', level int not null check(level between 1 and 4), created_at timestamptz default now());
create table public.products(id uuid primary key default gen_random_uuid(), name text unique not null, price int not null, stock int not null check(stock>=0));
create table public.prices(type text not null, duration int not null, price int not null, primary key(type,duration));
create table public.classes(id uuid primary key default gen_random_uuid(), day date not null, start_min int not null check(start_min>=480), duration int not null, type text not null check(type in ('exclusiva','semi','grupal')), discipline text not null check(discipline in ('esqui','snowboard')), language text not null default 'es' check(language in ('es','pt','en')), level int not null check(level between 1 and 4), instructor_id uuid not null references instructors, sector_id uuid not null references sectors, status text not null default 'programada' check(status in ('programada','confirmada','en_curso','dictada','afectada_viento','cancelada')), review boolean not null default false, cancel_reason text, version int not null default 1, created_at timestamptz not null default now(), check(start_min+duration<=1080));
create table public.enrollments(id uuid primary key default gen_random_uuid(), class_id uuid not null references classes, student_id uuid not null references students, status text not null check(status in ('confirmada','espera','cancelada')), present boolean not null default false, notification text, created_at timestamptz not null default now(), unique(class_id,student_id));
create table public.availability(id uuid primary key default gen_random_uuid(), instructor_id uuid not null references instructors, day date not null, start_min int not null, end_min int not null, reason text not null default 'No disponible', check(end_min>start_min));
create table public.closures(id uuid primary key default gen_random_uuid(), sector_id uuid not null references sectors, day date not null, start_min int not null, end_min int not null, active boolean not null default true, check(end_min>start_min));
create table public.rentals(id uuid primary key default gen_random_uuid(), student_id uuid not null references students, class_id uuid references classes, product_id uuid not null references products, day date not null, quantity int not null check(quantity>0), status text not null default 'reservado' check(status in ('reservado','cancelado')), payment text not null default 'pendiente' check(payment in ('pagado','pendiente')), version int not null default 1);
create table public.finances(class_id uuid primary key references classes, amount int not null default 0, payment text not null default 'pendiente' check(payment in ('pagado','pendiente')));
create table public.requests(actor uuid not null references profiles, request_id uuid not null, response jsonb not null, primary key(actor,request_id));
create function public.owns_class(cid uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from classes c join instructors i on i.id=c.instructor_id where c.id=cid and i.profile_id=auth.uid()) $$;
-- Policies are deliberately short: staff, coordination or assigned instructor.
alter table profiles enable row level security;
create policy profiles_read on profiles for select to authenticated using(id=auth.uid() or app_role()='coordinacion');
alter table instructors enable row level security;
create policy instructors_read on instructors for select to authenticated using(is_staff() or profile_id=auth.uid());
alter table sectors enable row level security;
create policy sectors_read on sectors for select to authenticated using(app_role() is not null);
alter table students enable row level security;
create policy students_read on students for select to authenticated using(is_staff() or exists(select 1 from enrollments e where e.student_id=students.id and owns_class(e.class_id)));
alter table classes enable row level security;
create policy classes_read on classes for select to authenticated using(is_staff() or owns_class(id));
alter table enrollments enable row level security;
create policy enrollments_read on enrollments for select to authenticated using(is_staff() or owns_class(class_id));
alter table availability enable row level security;
create policy availability_read on availability for select to authenticated using(is_staff() or exists(select 1 from instructors i where i.id=instructor_id and i.profile_id=auth.uid()));
alter table closures enable row level security;
create policy closures_read on closures for select to authenticated using(app_role() is not null);
alter table products enable row level security;
create policy products_read on products for select to authenticated using(is_staff());
alter table prices enable row level security;
create policy prices_read on prices for select to authenticated using(is_staff());
alter table rentals enable row level security;
create policy rentals_read on rentals for select to authenticated using(is_staff());
alter table finances enable row level security;
create policy finances_read on finances for select to authenticated using(app_role()='coordinacion');
alter table requests enable row level security;
-- No browser policy for requests. Only RPC can access idempotency log.
revoke all on all tables in schema public from anon, authenticated;
grant select on profiles,instructors,sectors,students,classes,enrollments,availability,closures,products,prices,rentals,finances to authenticated;
create function public.clock_text(m int) returns text language sql immutable as $$ select lpad((m/60)::text,2,'0')||':'||lpad((m%60)::text,2,'0') $$;

-- The only class validator. Called by preview, edit, booking and wind suggestions.
create function public.validate_class(p jsonb, exclude_class_id uuid default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare errors jsonb:='[]'; ins instructors; sec sectors; sid uuid; d date; st int; dur int; typ text; disc text; lang text; ids uuid[]; n int; lo int; hi int; hours numeric; clash classes; t int; used int;
begin
 if not is_staff() then raise exception 'No tenés permiso para validar clases.'; end if;
 d:=(p->>'day')::date; st:=(p->>'start_min')::int; dur:=(p->>'duration')::int; typ:=p->>'type';disc:=p->>'discipline';lang:=coalesce(p->>'language','es');
 select coalesce(array_agg(value::uuid),'{}') into ids from jsonb_array_elements_text(coalesce(p->'student_ids','[]'));
 select count(*),min(level),max(level) into n,lo,hi from students where id=any(ids);
 if n<>cardinality(ids) then errors:=errors||jsonb_build_array(jsonb_build_object('code','students','message','Revisá los alumnos: hay datos repetidos o que ya no existen.')); end if;
 hi:=coalesce(hi,(p->>'level')::int,1);lo:=coalesce(lo,hi);
 if d is null or st is null or dur is null or typ is null or disc is null or hi not between 1 and 4 or disc not in ('esqui','snowboard') or lang not in ('es','pt','en') then errors:=errors||'[{"code":"required","message":"Completá fecha, hora, disciplina y nivel."}]';end if;
 if not exists(select 1 from prices where type=typ and duration=dur) or st<480 or st+dur>1080 then errors:=errors||'[{"code":"schedule","message":"Elegí una duración del catálogo y un horario entre las 08:00 y las 18:00."}]'; end if;
 if (typ='exclusiva' and (n<1 or n>3)) or (typ='semi' and (n<4 or n>6)) or (typ='grupal' and n>8) then errors:=errors||'[{"code":"size","message":"El cupo es de 1 a 3 en exclusivas, de 4 a 6 en semi y hasta 8 en grupales."}]';end if;
 if dur=360 and st<>600 then errors:=errors||'[{"code":"full_day","message":"El día completo va de 10:00 a 16:00, con almuerzo de 13:00 a 14:00."}]';end if;
 if typ='grupal' and (st<>600 or dur<>120 or hi-lo>1 or exists(select 1 from students where id=any(ids) and birth_date>=d-interval '16 years')) then errors:=errors||'[{"code":"group","message":"La grupal empieza a las 10:00, dura 2 horas y admite mayores de 15 años de hasta dos niveles consecutivos."}]';end if;
 select * into ins from instructors where id=(p->>'instructor_id')::uuid;
 select * into sec from sectors where id=(p->>'sector_id')::uuid;
 if ins.id is null then errors:=errors||'[{"code":"instructor","message":"Elegí un instructor habilitado."}]';
 else
 if not disc=any(ins.disciplines) or ins.max_level<hi then errors:=errors||'[{"code":"qualification","message":"Ese instructor no está habilitado para la disciplina y el nivel de esta clase."}]';end if;
 if not lang=any(ins.languages) then errors:=errors||'[{"code":"language","message":"Ese instructor no dicta en el idioma elegido."}]';end if;
 if extract(dow from d)::int=any(ins.days_off) or exists(select 1 from availability where instructor_id=ins.id and day=d and start_min<st+dur and end_min>st) then errors:=errors||'[{"code":"unavailable","message":"El instructor tiene ese bloque marcado como no disponible."}]';end if;
 select * into clash from classes where day=d and instructor_id=ins.id and status<>'cancelada' and id is distinct from exclude_class_id and start_min<st+dur+30 and start_min+duration+30>st order by start_min limit 1;
 if clash.id is not null then errors:=errors||jsonb_build_array(jsonb_build_object('code','overlap','message','Ese horario ya lo tiene tomado otra clase de '||clock_text(clash.start_min)||' a '||clock_text(clash.start_min+clash.duration)||'. Dejá 30 minutos entre clases.'));end if;
 select coalesce(sum(case when duration=360 then 300 else duration end),0)/60.0 into hours from classes where day=d and instructor_id=ins.id and status<>'cancelada' and id is distinct from exclude_class_id;
 if hours+(case when dur=360 then 300 else dur end)/60.0>ins.max_hours then errors:=errors||'[{"code":"hours","message":"Con esta clase el instructor supera su tope diario de horas."}]';end if;
 end if;
 if sec.id is null or not hi=any(sec.levels) or not lo=any(sec.levels) then errors:=errors||'[{"code":"sector_level","message":"Ese sector no admite todos los niveles de la clase."}]';end if;
 if exists(select 1 from closures where sector_id=sec.id and day=d and active and start_min<st+dur and end_min>st) then errors:=errors||'[{"code":"closed","message":"El sector está cerrado en ese horario."}]';end if;
 -- Sweep each event boundary. Half-open [start,end): ending classes free space immediately.
 for t in select st union select c.start_min from classes c where c.day=d and c.sector_id=sec.id and c.status<>'cancelada' and c.id is distinct from exclude_class_id and c.start_min>=st and c.start_min<st+dur union select c.start_min+c.duration from classes c where c.day=d and c.sector_id=sec.id and c.status<>'cancelada' and c.id is distinct from exclude_class_id and c.start_min+c.duration>=st and c.start_min+c.duration<st+dur loop
 select coalesce(sum((select count(*) from enrollments e where e.class_id=c.id and e.status='confirmada')),0) into used from classes c where c.day=d and c.sector_id=sec.id and c.status<>'cancelada' and c.id is distinct from exclude_class_id and c.start_min<=t and c.start_min+c.duration>t;
 if used+n>sec.capacity then errors:=errors||jsonb_build_array(jsonb_build_object('code','capacity','message','En '||sec.name||' no queda lugar a las '||clock_text(t)||'. El cupo es de '||sec.capacity||' alumnos.'));exit;end if;
 end loop;
 if exists(select 1 from enrollments e join classes c on c.id=e.class_id where e.student_id=any(ids) and e.status='confirmada' and c.day=d and c.status<>'cancelada' and c.id is distinct from exclude_class_id and c.start_min<st+dur and c.start_min+c.duration>st) then errors:=errors||'[{"code":"student_overlap","message":"Un alumno ya tiene otra clase en ese horario."}]';end if;
 return errors;
end $$;

create function public.class_proposal(cid uuid) returns jsonb language sql stable security definer set search_path=public as $$ select to_jsonb(c)||jsonb_build_object('student_ids',coalesce((select jsonb_agg(student_id) from enrollments where class_id=c.id and status='confirmada'),'[]')) from classes c where c.id=cid and is_staff() $$;
create function public.quote_class(p jsonb) returns int language sql stable security definer set search_path=public as $$ select case when not is_staff() then null when p->>'type'='grupal' then (select price from prices where type='grupal' and duration=120)*jsonb_array_length(p->'student_ids') else (select price from prices where type=p->>'type' and duration=(p->>'duration')::int)+case when p->>'type'='exclusiva' then greatest(0,jsonb_array_length(p->'student_ids')-1)*60000 else 0 end end $$;
create function public.family_text(cid uuid) returns text language sql stable security definer set search_path=public as $$ select case when is_staff() then 'COTA · Tu clase de '||case discipline when 'esqui' then 'esquí' else 'snowboard' end||' es el '||to_char(day,'DD/MM/YYYY')||' de '||clock_text(start_min)||' a '||clock_text(start_min+duration)||' en '||(select name from sectors where id=sector_id)||'. Llegá a las '||clock_text(start_min-90)||' (una hora y media antes) para alquilar el equipo y comprar el pase.'||case when duration=360 then ' Almuerzo de 13:00 a 14:00.' else '' end||' Si cambia el sector, te avisamos por este medio.' else null end from classes where id=cid $$;

create function public.mutate(action text, p jsonb, request_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb; old classes; target classes; cid uuid; sid uuid; e enrollments; next_e enrollments; ids jsonb; proposal jsonb; errors jsonb; cost int; qty int; remain int; role_name text:=app_role(); r rentals;
begin
 if auth.uid() is null or role_name is null then raise exception 'Ingresá con una cuenta habilitada.';end if;
 -- One short school-wide lock is simple and sufficient for a single school's daily desk.
 -- It serializes all capacity, roster, stock, closure and state changes.
 perform pg_advisory_xact_lock(72463026);
 select response into result from requests q where q.actor=auth.uid() and q.request_id=mutate.request_id;
 if found then return result;end if;
 if role_name='instructor' and action<>'dictate' then raise exception 'Solo podés marcar tus clases como dictadas.';end if;
 if action in ('wind','reopen','merge','availability','configure') and role_name<>'coordinacion' then raise exception 'Esta acción es de coordinación.';end if;
 if p ? 'class_id' then
 select * into old from classes where id=(p->>'class_id')::uuid for update;
 if not found then raise exception 'La clase ya no existe. Actualizá los datos.';end if;
 if role_name='instructor' and not owns_class(old.id) then raise exception 'No tenés acceso a esa clase.';end if;
 if old.status='dictada' and action<>'payment' then raise exception 'Una clase dictada ya no se modifica.';end if;
 if (p->>'version') is null or old.version<>(p->>'version')::int then raise exception 'La clase cambió en otra pantalla. Actualizá los datos.';end if;
 if old.status='cancelada' then raise exception 'La clase ya está cancelada. Actualizá los datos.';end if;
 end if;
 case action
 when 'configure' then
 if p->>'entity'='instructor' then
 update instructors set name=trim(p->>'name'),disciplines=array(select jsonb_array_elements_text(p->'disciplines')),max_level=(p->>'max_level')::int,languages=array(select jsonb_array_elements_text(p->'languages')),max_hours=(p->>'max_hours')::numeric,days_off=array(select value::int from jsonb_array_elements_text(p->'days_off')) where id=(p->>'id')::uuid;
 if not exists(select 1 from instructors where id=(p->>'id')::uuid and name<>'' and cardinality(disciplines)>0 and disciplines<@array['esqui','snowboard'] and 'es'=any(languages) and languages<@array['es','pt','en'] and max_hours>0 and max_hours<=6 and days_off<@array[0,1,2,3,4,5,6]) then raise exception 'Revisá las habilitaciones, idiomas y tope del instructor.';end if;
 elsif p->>'entity'='sector' then
 update sectors set capacity=(p->>'capacity')::int where id=(p->>'id')::uuid;
 elsif p->>'entity'='product' then
 update products set stock=(p->>'stock')::int,price=(p->>'price')::int where id=(p->>'id')::uuid and (p->>'price')::int>=0;
 if not found then raise exception 'Revisá el producto y su precio.';end if;
 if exists(select 1 from rentals where product_id=(p->>'id')::uuid and status='reservado' group by day having sum(quantity)>(p->>'stock')::int) then raise exception 'El stock nuevo no alcanza para las reservas actuales.';end if;
 elsif p->>'entity'='price' then
 update prices set price=(p->>'price')::int where type=p->>'type' and duration=(p->>'duration')::int and (p->>'price')::int>=0;
 else raise exception 'Configuración desconocida.';end if;
 -- A catalog change cannot silently invalidate scheduled classes.
 if p->>'entity' in ('instructor','sector') then
 for target in select * from classes where status in ('programada','confirmada','en_curso') and ((p->>'entity'='instructor' and instructor_id=(p->>'id')::uuid) or (p->>'entity'='sector' and sector_id=(p->>'id')::uuid)) loop
 errors:=validate_class(class_proposal(target.id),target.id);
 if jsonb_array_length(errors)>0 then raise exception 'Ese cambio afecta una clase asignada: %',errors->0->>'message';end if;
 end loop;
 end if;
 result:='{"ok":true}';
 when 'student' then
 insert into students(name,birth_date,phone,level) values(trim(p->>'name'),(p->>'birth_date')::date,coalesce(p->>'phone',''),(p->>'level')::int) returning id into sid;
 if trim(p->>'name')='' then raise exception 'Ingresá el nombre del alumno.';end if;
 result:=jsonb_build_object('id',sid);
 when 'save_class' then
 proposal:=p;
 if old.id is not null and (old.discipline<>p->>'discipline' or old.level<>(p->>'level')::int) then raise exception 'La edición conserva la disciplina y el nivel de la clase.';end if;
 errors:=validate_class(proposal,old.id);
 if jsonb_array_length(errors)>0 then return jsonb_build_object('errors',errors);end if;
 select max(level) into qty from students where id in(select value::uuid from jsonb_array_elements_text(p->'student_ids'));
 if old.id is not null and qty is not null and qty<>old.level then raise exception 'Los alumnos deben conservar el nivel de la clase. Creá una nueva propuesta para cambiarlo.';end if;
 if old.id is null then
 insert into classes(day,start_min,duration,type,discipline,language,level,instructor_id,sector_id,status) values((p->>'day')::date,(p->>'start_min')::int,(p->>'duration')::int,p->>'type',p->>'discipline',p->>'language',coalesce(qty,(p->>'level')::int),(p->>'instructor_id')::uuid,(p->>'sector_id')::uuid,'confirmada') returning id into cid;
 else
 cid:=old.id;
 update classes set day=(p->>'day')::date,start_min=(p->>'start_min')::int,duration=(p->>'duration')::int,type=p->>'type',language=p->>'language',instructor_id=(p->>'instructor_id')::uuid,sector_id=(p->>'sector_id')::uuid,status='confirmada',version=version+1 where id=cid;
 if exists(select 1 from rentals where class_id=cid and status='reservado') and old.day<>(p->>'day')::date then raise exception 'Cancelá o reubicá primero los alquileres de la clase para cambiar la fecha.';end if;
 end if;
 -- Keep FIFO history. Do not delete waiting-list entries during edits.
 update enrollments set status='cancelada' where class_id=cid and status='confirmada' and student_id not in(select value::uuid from jsonb_array_elements_text(p->'student_ids'));
 insert into enrollments(class_id,student_id,status) select cid,value::uuid,'confirmada' from jsonb_array_elements_text(p->'student_ids') on conflict(class_id,student_id) do update set status='confirmada';
 insert into finances(class_id,amount) values(cid,quote_class(proposal)) on conflict(class_id) do update set amount=excluded.amount;
 result:=jsonb_build_object('id',cid,'text',family_text(cid));
 when 'enroll' then
 if old.type<>'grupal' then raise exception 'Usá la edición para inscribir en una exclusiva o semi.';end if;
 sid:=(p->>'student_id')::uuid;
 if exists(select 1 from enrollments where class_id=old.id and student_id=sid and status<>'cancelada') then raise exception 'Ese alumno ya está inscripto.';end if;
 proposal:=class_proposal(old.id);
 select count(*) into qty from enrollments where class_id=old.id and status='confirmada';
 proposal:=jsonb_set(proposal,'{student_ids}',(proposal->'student_ids')||jsonb_build_array(sid));
 -- Waitlisted students must also meet age/level rules, even with a full group.
 if qty>=8 then
 errors:=validate_class(proposal,old.id);
 if exists(select 1 from jsonb_array_elements(errors) x where x->>'code' in ('students','group','qualification','language','sector_level')) then return jsonb_build_object('errors',(select jsonb_agg(x) from jsonb_array_elements(errors) x where x->>'code' in ('students','group','qualification','language','sector_level')));end if;
 insert into enrollments(class_id,student_id,status) values(old.id,sid,'espera') on conflict(class_id,student_id) do update set status='espera',created_at=now();
 result:=jsonb_build_object('waiting',true);
 else
 errors:=validate_class(proposal,old.id);
 if jsonb_array_length(errors)>0 then return jsonb_build_object('errors',errors);end if;
 insert into enrollments(class_id,student_id,status) values(old.id,sid,'confirmada') on conflict(class_id,student_id) do update set status='confirmada',created_at=now();
 update finances set amount=quote_class(proposal) where class_id=old.id;
 result:=jsonb_build_object('text',family_text(old.id));
 end if;
 update classes set version=version+1,level=coalesce((select max(s.level) from enrollments en join students s on s.id=en.student_id where en.class_id=old.id and en.status='confirmada'),level) where id=old.id;
 when 'cancel_enrollment' then
 if old.type<>'grupal' then raise exception 'Para una exclusiva o semi, editá la clase completa o cancelala.';end if;
 select * into e from enrollments where id=(p->>'enrollment_id')::uuid and class_id=old.id for update;
 if e.id is null or e.status='cancelada' then raise exception 'Esa inscripción ya cambió. Actualizá los datos.';end if;
 update enrollments set status='cancelada' where id=e.id;
 -- Strict FIFO: do not silently skip a person; incompatible head stays for manual review.
 if e.status='confirmada' then
 select * into next_e from enrollments where class_id=old.id and status='espera' order by created_at,id limit 1 for update;
 if next_e.id is not null then
 proposal:=class_proposal(old.id);proposal:=jsonb_set(proposal,'{student_ids}',(proposal->'student_ids')||jsonb_build_array(next_e.student_id));
 errors:=validate_class(proposal,old.id);
 if jsonb_array_length(errors)=0 then update enrollments set status='confirmada',notification='Se liberó un lugar. '||family_text(old.id) where id=next_e.id;else update enrollments set notification='Coordinación debe revisar el pase desde lista de espera.' where id=next_e.id;end if;
 end if;
 end if;
 update classes set version=version+1,level=coalesce((select max(s.level) from enrollments en join students s on s.id=en.student_id where en.class_id=old.id and en.status='confirmada'),level) where id=old.id;
 update finances set amount=quote_class(class_proposal(old.id)) where class_id=old.id;
 result:=jsonb_build_object('promoted',next_e.id);
 when 'cancel_class' then
 if nullif(trim(p->>'reason'),'') is null then raise exception 'Indicá el motivo de cancelación.';end if;
 update classes set status='cancelada',cancel_reason=p->>'reason',version=version+1 where id=old.id;
 update rentals set status='cancelado',version=version+1 where class_id=old.id and status<>'cancelado';
 update enrollments set status='cancelada' where class_id=old.id;
 result:=jsonb_build_object('id',old.id);
 when 'start' then
 if old.status<>'confirmada' then raise exception 'Solo se puede iniciar una clase confirmada.';end if;
 update classes set status='en_curso',version=version+1 where id=old.id;result:=jsonb_build_object('id',old.id);
 when 'dictate' then
 if old.status not in ('confirmada','en_curso') then raise exception 'Solo se puede dictar una clase confirmada o en curso.';end if;
 update enrollments set present=student_id in(select value::uuid from jsonb_array_elements_text(coalesce(p->'present_ids','[]'))) where class_id=old.id and status='confirmada';
 update classes set status='dictada',version=version+1 where id=old.id;result:=jsonb_build_object('id',old.id);
 when 'rent' then
 select stock-coalesce((select sum(quantity) from rentals where product_id=pr.id and day=(p->>'day')::date and status='reservado'),0) into remain from products pr where id=(p->>'product_id')::uuid for update;
 qty:=(p->>'quantity')::int;
 if remain is null or qty is null or qty<1 or remain<qty then raise exception 'No queda stock suficiente para ese día. Actualizá los datos.';end if;
 if old.id is not null and old.day<>(p->>'day')::date then raise exception 'El alquiler tiene que ser para la fecha de la clase.';end if;
 insert into rentals(student_id,class_id,product_id,day,quantity) values((p->>'student_id')::uuid,old.id,(p->>'product_id')::uuid,(p->>'day')::date,qty) returning id into sid;
 result:=jsonb_build_object('id',sid);
 when 'rental_state' then
 select * into r from rentals where id=(p->>'rental_id')::uuid for update;
 if r.id is null or r.version<>(p->>'rental_version')::int or r.status='cancelado' then raise exception 'El alquiler cambió. Actualizá los datos.';end if;
 if r.class_id is not null and exists(select 1 from classes where id=r.class_id and status='dictada') then raise exception 'El alquiler pertenece a una clase dictada.';end if;
 update rentals set status=coalesce(p->>'status',status),payment=coalesce(p->>'payment',payment),version=version+1 where id=r.id;result:=jsonb_build_object('id',r.id);
 when 'payment' then
 update finances set payment=p->>'payment' where class_id=old.id;result:=jsonb_build_object('id',old.id);
 when 'wind' then
 if not exists(select 1 from sectors where id=(p->>'sector_id')::uuid and wind_sensitive) then raise exception 'Ese sector no se cierra por viento.';end if;
 insert into closures(sector_id,day,start_min,end_min) values((p->>'sector_id')::uuid,(p->>'day')::date,(p->>'start_min')::int,(p->>'end_min')::int);
 update classes set status='afectada_viento',version=version+1 where sector_id=(p->>'sector_id')::uuid and day=(p->>'day')::date and status in ('programada','confirmada','en_curso') and start_min<(p->>'end_min')::int and start_min+duration>(p->>'start_min')::int;
 result:='{"ok":true}';
 when 'reopen' then
 update closures set active=false where id=(p->>'closure_id')::uuid;result:='{"ok":true}';
 when 'relocate' then
 if old.status<>'afectada_viento' then raise exception 'La clase ya no está afectada por viento.';end if;
 proposal:=class_proposal(old.id)||jsonb_build_object('sector_id',p->>'sector_id','start_min',(p->>'start_min')::int);
 errors:=validate_class(proposal,old.id);if jsonb_array_length(errors)>0 then return jsonb_build_object('errors',errors);end if;
 update classes set sector_id=(p->>'sector_id')::uuid,start_min=(p->>'start_min')::int,status='confirmada',version=version+1 where id=old.id;result:=jsonb_build_object('text',family_text(old.id));
 when 'merge' then
 if old.type<>'grupal' then raise exception 'Solo se fusionan grupales.';end if;
 select * into target from classes where id=(p->>'target_id')::uuid for update;
 if target.id=old.id or target.id is null or target.type<>'grupal' or target.status not in ('programada','confirmada') or target.day<>old.day or target.discipline<>old.discipline or target.language<>old.language then raise exception 'Elegí otra grupal compatible del mismo día.';end if;
 if target.version<>(p->>'target_version')::int then raise exception 'La grupal destino cambió. Actualizá los datos.';end if;
 if exists(select 1 from rentals where class_id=old.id and status='reservado') then raise exception 'Revisá los alquileres de la clase antes de fusionar.';end if;
 select coalesce(jsonb_agg(distinct student_id),'[]') into ids from enrollments where class_id in(old.id,target.id) and status='confirmada';
 update classes set status='cancelada',cancel_reason='Fusión',version=version+1 where id=old.id;
 proposal:=class_proposal(target.id)||jsonb_build_object('student_ids',ids);
 errors:=validate_class(proposal,target.id);if jsonb_array_length(errors)>0 then raise exception '%',errors->0->>'message';end if;
 insert into enrollments(class_id,student_id,status) select target.id,student_id,status from enrollments where class_id=old.id and status in ('confirmada','espera') on conflict(class_id,student_id) do nothing;
 update enrollments set status='cancelada' where class_id=old.id;
 update classes set version=version+1,level=coalesce((select max(s.level) from enrollments en join students s on s.id=en.student_id where en.class_id=target.id and en.status='confirmada'),level) where id=target.id;
 update finances set amount=quote_class(class_proposal(target.id)) where class_id=target.id;
 result:=jsonb_build_object('text',family_text(target.id));
 when 'availability' then
 if exists(select 1 from classes where instructor_id=(p->>'instructor_id')::uuid and day=(p->>'day')::date and status<>'cancelada' and start_min<(p->>'end_min')::int and start_min+duration>(p->>'start_min')::int) then raise exception 'El bloqueo pisa una clase asignada. Reubicá la clase antes de guardar.';end if;
 insert into availability(instructor_id,day,start_min,end_min,reason) values((p->>'instructor_id')::uuid,(p->>'day')::date,(p->>'start_min')::int,(p->>'end_min')::int,coalesce(p->>'reason','No disponible'));result:='{"ok":true}';
 else raise exception 'Acción desconocida.';
 end case;
 insert into requests(actor,request_id,response) values(auth.uid(),mutate.request_id,result);
 return result;
end $$;

create function public.wind_options(cid uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare p jsonb; c classes; s sectors; t int; opts jsonb:='[]'; candidate jsonb;
begin
 if not is_staff() then raise exception 'No tenés permiso.';end if;
 select * into c from classes where id=cid and status='afectada_viento';if c.id is null then return opts;end if;
 p:=class_proposal(cid);
 -- All alternative sectors at same hour; refuge follows outdoor sectors.
 for s in select * from sectors where id<>c.sector_id order by indoor,name loop
 candidate:=p||jsonb_build_object('sector_id',s.id);
 if validate_class(candidate,cid)='[]'::jsonb then opts:=opts||jsonb_build_array(jsonb_build_object('sector_id',s.id,'start_min',c.start_min,'label',s.name||' · mismo horario'));end if;
 end loop;
 for t in 480..(1080-c.duration) by 30 loop
 if t=c.start_min then continue;end if;
 for s in select * from sectors order by indoor,name loop
 candidate:=p||jsonb_build_object('sector_id',s.id,'start_min',t);
 if validate_class(candidate,cid)='[]'::jsonb then opts:=opts||jsonb_build_array(jsonb_build_object('sector_id',s.id,'start_min',t,'label',s.name||' · '||clock_text(t)));end if;
 end loop;
 end loop;
 return opts;
end $$;
create function public.financial_day(d date) returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if app_role()<>'coordinacion' or app_role() is null then raise exception 'Solo coordinación ve la liquidación y la facturación.';end if;
 return jsonb_build_object('classes',(select coalesce(jsonb_agg(jsonb_build_object('class_id',c.id,'instructor_id',c.instructor_id,'type',c.type,'status',c.status,'amount',f.amount,'payment',f.payment,'hours',case when c.duration=360 then 5 else c.duration/60.0 end,'fee',case when c.status<>'dictada' then 0 when c.type='grupal' then 18000*(select count(*) from enrollments where class_id=c.id and status='confirmada' and present) when c.type='exclusiva' then round(f.amount*.35) else round(f.amount*.30) end,'cancel_reason',c.cancel_reason)),'[]') from classes c join finances f on f.class_id=c.id where c.day=d));
end $$;
-- Remove default PUBLIC execute (including security definer helpers).
revoke execute on all functions in schema public from public,anon,authenticated;
grant execute on function app_role(),is_staff(),owns_class(uuid),validate_class(jsonb,uuid),class_proposal(uuid),quote_class(jsonb),family_text(uuid),mutate(text,jsonb,uuid),wind_options(uuid),financial_day(date) to authenticated;
