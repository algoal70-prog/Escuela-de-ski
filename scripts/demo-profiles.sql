insert into auth.users(id,email) values('00000000-0000-4000-0001-000000000001','coordinacion@cota.test'),('00000000-0000-4000-0001-000000000002','recepcion@cota.test'),('00000000-0000-4000-0001-000000000003','instructor@cota.test');
insert into profiles(id,name,role) values('00000000-0000-4000-0001-000000000001','Coordinación Demo','coordinacion'),('00000000-0000-4000-0001-000000000002','Recepción Demo','recepcion'),('00000000-0000-4000-0001-000000000003','Lara Lagos','instructor');
update instructors set profile_id='00000000-0000-4000-0001-000000000003' where id='00000000-0000-4000-0002-000000000001';
select set_config('request.jwt.claim.sub','00000000-0000-4000-0001-000000000001',false);
