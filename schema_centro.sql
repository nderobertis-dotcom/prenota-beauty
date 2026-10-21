-- ============================================================
-- SCHEMA: Prenotazioni Centro Estetico (multi-operatore, single-tenant)
-- ============================================================
-- Un solo centro, più operatori. Ogni prenotazione riguarda UN operatore
-- (più servizi dello stesso operatore possono essere concatenati).
-- Esegui nel SQL Editor del NUOVO progetto Supabase (non quello di Ignazio).
-- Dopo l'esecuzione:
--   1) crea gli utenti admin in Authentication > Users
--   2) inserisci le loro email in admin_emails (vedi fondo file)
--   3) personalizza operatori / servizi / orari / festività

create extension if not exists btree_gist;

-- ---------- ADMIN ----------
create table if not exists admin_emails (
  email text primary key
);
alter table admin_emails enable row level security;
-- nessuna policy: la tabella non è leggibile da anon/authenticated via API

create or replace function is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from admin_emails
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;
grant execute on function is_admin() to anon, authenticated;

-- ---------- OPERATORI ----------
create table if not exists operatori (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  attivo boolean not null default true,
  ordine int not null default 0
);

-- ---------- SERVIZI (appartengono a un operatore) ----------
create table if not exists servizi (
  id uuid primary key default gen_random_uuid(),
  operatore_id uuid not null references operatori(id),
  nome text not null,
  durata_minuti int not null check (durata_minuti > 0),
  prezzo numeric(10,2),
  attivo boolean not null default true,
  ordine int not null default 0
);
create index if not exists idx_servizi_operatore on servizi (operatore_id);

-- ---------- ORARI (per operatore e giorno) ----------
-- giorno_settimana: 0 = domenica ... 6 = sabato
create table if not exists orari (
  operatore_id uuid not null references operatori(id) on delete cascade,
  giorno_settimana int not null check (giorno_settimana between 0 and 6),
  chiuso boolean not null default false,
  apertura time,
  chiusura time,
  pausa_inizio time,
  pausa_fine time,
  primary key (operatore_id, giorno_settimana),
  check (chiuso or (apertura is not null and chiusura is not null and chiusura > apertura))
);

-- ---------- BLOCCHI (operatore_id NULL = tutto il centro) ----------
create table if not exists blocchi (
  id uuid primary key default gen_random_uuid(),
  operatore_id uuid references operatori(id) on delete cascade,
  inizio timestamptz not null,
  fine timestamptz not null,
  motivo text,
  check (fine > inizio)
);
create index if not exists idx_blocchi_range on blocchi using gist (tstzrange(inizio, fine, '[)'));

-- ---------- FESTIVITÀ FISSE ----------
create table if not exists festivita_fisse (
  mese int not null check (mese between 1 and 12),
  giorno int not null check (giorno between 1 and 31),
  nome text not null,
  primary key (mese, giorno)
);

-- ---------- PRENOTAZIONI ----------
create table if not exists prenotazioni (
  id uuid primary key default gen_random_uuid(),
  operatore_id uuid not null references operatori(id),
  nome_cliente text not null,
  telefono text not null,
  servizio_id uuid not null references servizi(id),
  inizio timestamptz not null,
  fine timestamptz not null,
  stato text not null default 'confermata' check (stato in ('confermata','annullata')),
  creato_il timestamptz not null default now(),
  check (fine > inizio),
  -- Anti-sovrapposizione PER OPERATORE: due operatori possono lavorare
  -- in parallelo, lo stesso operatore no.
  exclude using gist (
    operatore_id with =,
    tstzrange(inizio, fine, '[)') with &&
  ) where (stato = 'confermata')
);
create index if not exists idx_prenotazioni_op_inizio on prenotazioni (operatore_id, inizio);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table operatori enable row level security;
alter table servizi enable row level security;
alter table orari enable row level security;
alter table blocchi enable row level security;
alter table festivita_fisse enable row level security;
alter table prenotazioni enable row level security;

create policy operatori_public_select on operatori for select using (attivo = true);
create policy operatori_admin_all on operatori for all using (is_admin()) with check (is_admin());

create policy servizi_public_select on servizi for select
  using (attivo = true and exists (select 1 from operatori o where o.id = operatore_id and o.attivo));
create policy servizi_admin_all on servizi for all using (is_admin()) with check (is_admin());

create policy orari_public_select on orari for select using (true);
create policy orari_admin_all on orari for all using (is_admin()) with check (is_admin());

create policy festivita_public_select on festivita_fisse for select using (true);
create policy festivita_admin_all on festivita_fisse for all using (is_admin()) with check (is_admin());

-- blocchi e prenotazioni: nessun accesso pubblico diretto
create policy blocchi_admin_all on blocchi for all using (is_admin()) with check (is_admin());
create policy prenotazioni_admin_all on prenotazioni for all using (is_admin()) with check (is_admin());

-- ============================================================
-- FUNZIONE PUBBLICA: occupazione di un operatore in un giorno (no dati personali)
-- Usa overlap di intervalli sui confini del giorno in fuso Europe/Rome,
-- quindi i blocchi multi-giorno coprono anche i giorni intermedi.
-- Include i blocchi dell'operatore e quelli dell'intero centro.
-- ============================================================
create or replace function get_occupazione(p_data date, p_operatore uuid)
returns table (inizio timestamptz, fine timestamptz)
language sql stable security definer
set search_path = public
as $$
  with g as (
    select tstzrange((p_data::timestamp) at time zone 'Europe/Rome',
                     ((p_data + 1)::timestamp) at time zone 'Europe/Rome', '[)') as r
  )
  select p.inizio, p.fine from prenotazioni p, g
  where p.stato = 'confermata' and p.operatore_id = p_operatore
    and tstzrange(p.inizio, p.fine, '[)') && g.r
  union all
  select b.inizio, b.fine from blocchi b, g
  where (b.operatore_id is null or b.operatore_id = p_operatore)
    and tstzrange(b.inizio, b.fine, '[)') && g.r;
$$;
grant execute on function get_occupazione(date, uuid) to anon, authenticated;

-- ============================================================
-- FUNZIONE PUBBLICA: crea prenotazione (1+ servizi dello STESSO operatore,
-- in sequenza). Atomica e validata lato server: il client non è fidato.
-- ============================================================
create or replace function crea_prenotazione(
  p_nome_cliente text,
  p_telefono text,
  p_servizio_ids uuid[],
  p_inizio timestamptz
) returns int
language plpgsql security definer
set search_path = public
as $$
declare
  v_n int := coalesce(array_length(p_servizio_ids, 1), 0);
  v_op uuid;
  v_cnt int;
  v_nop int;
  v_tot int;
  v_fine_tot timestamptz;
  v_loc_inizio timestamp := p_inizio at time zone 'Europe/Rome';
  v_loc_fine timestamp;
  v_orario orari%rowtype;
  v_cursore timestamptz := p_inizio;
  v_sid uuid;
  v_dur int;
begin
  if length(trim(coalesce(p_nome_cliente,''))) < 2 or length(trim(coalesce(p_telefono,''))) < 6 then
    raise exception 'dati cliente non validi' using errcode = 'P0001';
  end if;
  if v_n < 1 or v_n > 10 then
    raise exception 'numero servizi non valido' using errcode = 'P0001';
  end if;
  if p_inizio < now() then
    raise exception 'orario nel passato' using errcode = 'P0001';
  end if;
  if extract(minute from v_loc_inizio)::int % 5 <> 0 or extract(second from v_loc_inizio) <> 0 then
    raise exception 'orario non valido' using errcode = 'P0001';
  end if;

  -- servizi: tutti esistenti, attivi, senza duplicati, dello stesso operatore attivo
  select count(*), count(distinct s.operatore_id), min(s.operatore_id::text)::uuid, coalesce(sum(s.durata_minuti),0)
    into v_cnt, v_nop, v_op, v_tot
  from servizi s join operatori o on o.id = s.operatore_id
  where s.id = any(p_servizio_ids) and s.attivo and o.attivo;
  if v_cnt <> v_n or v_nop <> 1
     or (select count(distinct x) from unnest(p_servizio_ids) x) <> v_n then
    raise exception 'servizi non validi' using errcode = 'P0001';
  end if;

  v_fine_tot := p_inizio + make_interval(mins => v_tot);
  v_loc_fine := v_fine_tot at time zone 'Europe/Rome';

  -- stesso giorno locale
  if v_loc_fine::date <> v_loc_inizio::date then
    raise exception 'fuori orario' using errcode = 'P0001';
  end if;

  -- festività
  if exists (select 1 from festivita_fisse
             where mese = extract(month from v_loc_inizio)::int
               and giorno = extract(day from v_loc_inizio)::int) then
    raise exception 'giorno festivo' using errcode = 'P0001';
  end if;

  -- orari dell'operatore
  select * into v_orario from orari
  where operatore_id = v_op and giorno_settimana = extract(dow from v_loc_inizio)::int;
  if not found or v_orario.chiuso
     or v_loc_inizio::time < v_orario.apertura
     or v_loc_fine::time > v_orario.chiusura then
    raise exception 'fuori orario' using errcode = 'P0001';
  end if;
  if v_orario.pausa_inizio is not null and v_orario.pausa_fine is not null
     and v_loc_inizio::time < v_orario.pausa_fine and v_loc_fine::time > v_orario.pausa_inizio then
    raise exception 'in pausa' using errcode = 'P0001';
  end if;

  -- blocchi (operatore o centro)
  if exists (select 1 from blocchi b
             where (b.operatore_id is null or b.operatore_id = v_op)
               and tstzrange(b.inizio, b.fine, '[)') && tstzrange(p_inizio, v_fine_tot, '[)')) then
    raise exception 'periodo bloccato' using errcode = 'P0001';
  end if;

  -- inserimento sequenziale: l'EXCLUDE segnala 23P01 e annulla tutto
  foreach v_sid in array p_servizio_ids loop
    select durata_minuti into v_dur from servizi where id = v_sid;
    insert into prenotazioni (operatore_id, nome_cliente, telefono, servizio_id, inizio, fine)
    values (v_op, trim(p_nome_cliente), trim(p_telefono), v_sid,
            v_cursore, v_cursore + make_interval(mins => v_dur));
    v_cursore := v_cursore + make_interval(mins => v_dur);
  end loop;

  return v_n;
end;
$$;
grant execute on function crea_prenotazione(text, text, uuid[], timestamptz) to anon, authenticated;

-- ============================================================
-- DATI DI ESEMPIO — SOSTITUIRE con i dati reali del centro
-- ============================================================
insert into operatori (nome, ordine) values ('Operatrice 1', 1), ('Operatrice 2', 2);

insert into servizi (operatore_id, nome, durata_minuti, prezzo, ordine)
select o.id, s.nome, s.durata, s.prezzo, s.ord
from operatori o
join (values
  ('Operatrice 1', 'Pulizia viso', 60, 45.00, 1),
  ('Operatrice 1', 'Manicure',     45, 20.00, 2),
  ('Operatrice 2', 'Ceretta gambe',40, 25.00, 1),
  ('Operatrice 2', 'Massaggio',    50, 40.00, 2)
) as s(op, nome, durata, prezzo, ord) on s.op = o.nome;

-- Orari: lun–ven 09:00–19:00 con pausa 13:00–15:00, sab 09:00–13:00, dom chiuso (esempio)
insert into orari (operatore_id, giorno_settimana, chiuso, apertura, chiusura, pausa_inizio, pausa_fine)
select o.id, d.g,
       d.g = 0,
       case when d.g = 0 then null else '09:00'::time end,
       case when d.g = 0 then null when d.g = 6 then '13:00'::time else '19:00'::time end,
       case when d.g between 1 and 5 then '13:00'::time end,
       case when d.g between 1 and 5 then '15:00'::time end
from operatori o cross join generate_series(0, 6) as d(g);

-- Festività nazionali a data fissa. Pasqua/Pasquetta sono MOBILI: non incluse
-- (aggiungere a mano ogni anno come blocco "tutto il centro"). Aggiungere il santo patrono locale.
insert into festivita_fisse (mese, giorno, nome) values
  (1,1,'Capodanno'),(1,6,'Epifania'),(4,25,'Festa della Liberazione'),(5,1,'Festa del Lavoro'),
  (6,2,'Festa della Repubblica'),(8,15,'Ferragosto'),(11,1,'Ognissanti'),
  (12,8,'Immacolata Concezione'),(12,25,'Natale'),(12,26,'Santo Stefano');
-- insert into festivita_fisse values (MESE, GIORNO, 'Santo Patrono ...');

-- Admin: sostituire con le email reali (devono esistere in Authentication > Users)
insert into admin_emails (email) values ('nderobertis@gmail.com');
