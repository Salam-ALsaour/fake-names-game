-- =====================================================================
-- قاعدة بيانات لعبة "طويق ضد لييب" (مشروع Supabase: Seraj)
-- هذا الملف للتوثيق: يوصف الحالة الحالية المطبقة على قاعدة البيانات.
--
-- الفكرة:
--   - جدول اللاعبين مقفول تماماً عن المتصفح؛ كل القراءة والكتابة تمر
--     عبر دوال (RPC) تتحقق من الصلاحيات.
--   - اللاعب العادي: يسجل اسم واحد بس لكل جهاز (device_id)، ويشوف عناوين
--     البطاقات فقط؛ الأسماء والألوان مخفية لين تنكشف البطاقة.
--   - الآدمن (كلمة السر في الرابط #admin=...): يضيف بدون حد، يحذف أي أحد،
--     يبدأ المباراة، يكشف البطاقات، وينهيها.
--   - game_state جدول عام فيه حالة المباراة (بدون أسماء)، والمتصفحات تتابعه
--     مباشرة (Realtime) وتعيد طلب game_view عند أي تغيير.
--
-- تغيير كلمة سر الآدمن (شغّلها في SQL Editor في Supabase):
--   update game_private.config
--   set admin_key_hash = extensions.crypt('كلمة_السر_الجديدة', extensions.gen_salt('bf'))
--   where id = 1;
-- =====================================================================

-- ---------- اللاعبين ----------
create table public.game_players (
  id bigint generated always as identity primary key,
  title text not null check (char_length(title) between 1 and 100),
  player_name text not null check (char_length(player_name) between 1 and 100),
  color text not null check (color in ('blue', 'red', 'green')),
  created_at timestamptz not null default now(),
  device_id uuid  -- null = أضافه الآدمن
);
create unique index game_players_one_per_device on public.game_players (device_id) where device_id is not null;
alter table public.game_players enable row level security;  -- بدون policies: ممنوع الوصول المباشر

-- ---------- حالة المباراة المشتركة ----------
create table public.game_state (
  id int primary key default 1 check (id = 1),
  phase text not null default 'setup' check (phase in ('setup', 'playing', 'ended')),
  card_ids bigint[] not null default '{}',
  revealed_ids bigint[] not null default '{}',
  version bigint not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.game_state (id) values (1);
alter table public.game_state enable row level security;
create policy "game_state_select" on public.game_state for select to anon, authenticated using (true);
alter publication supabase_realtime add table public.game_state;

-- ---------- كلمة سر الآدمن (مشفرة، في سكيما غير مكشوفة) ----------
create schema game_private;
revoke all on schema game_private from public, anon, authenticated;
create table game_private.config (
  id int primary key default 1 check (id = 1),
  admin_key_hash text not null
);

create function game_private.is_admin(p_key text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(p_key, '') <> '' and exists (
    select 1 from game_private.config c
    where c.admin_key_hash = extensions.crypt(p_key, c.admin_key_hash)
  );
$$;

create function game_private.bump() returns void
language sql security definer set search_path = ''
as $$
  update public.game_state set version = version + 1, updated_at = now() where id = 1;
$$;

revoke all on all functions in schema game_private from public, anon, authenticated;

-- ---------- اللي يشوفه كل واحد ----------
create function public.game_view(p_device_id uuid default null, p_admin_key text default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_admin boolean := game_private.is_admin(p_admin_key);
  v_state public.game_state;
  v_players jsonb;
  v_cards jsonb;
  v_total int;
  v_blue int;
  v_red int;
begin
  select * into v_state from public.game_state where id = 1;

  select coalesce(jsonb_agg(
    case when v_admin or (p.device_id is not null and p.device_id = p_device_id) then
      jsonb_build_object('id', p.id, 'title', p.title, 'player_name', p.player_name, 'color', p.color,
                         'mine', p.device_id is not null and p.device_id = p_device_id)
    else
      jsonb_build_object('id', p.id, 'title', p.title, 'mine', false)
    end order by p.created_at, p.id), '[]'::jsonb)
  into v_players
  from public.game_players p;

  select
    coalesce(jsonb_agg(
      case when p.id = any(v_state.revealed_ids) then
        jsonb_build_object('id', p.id, 'title', p.title, 'revealed', true, 'player_name', p.player_name, 'color', p.color)
      else
        jsonb_build_object('id', p.id, 'title', p.title, 'revealed', false)
      end order by c.ord), '[]'::jsonb),
    count(p.id),
    count(p.id) filter (where p.color = 'blue' and p.id = any(v_state.revealed_ids)),
    count(p.id) filter (where p.color = 'red' and p.id = any(v_state.revealed_ids))
  into v_cards, v_total, v_blue, v_red
  from unnest(v_state.card_ids) with ordinality as c(id, ord)
  join public.game_players p on p.id = c.id;

  return jsonb_build_object(
    'is_admin', v_admin,
    'phase', v_state.phase,
    'version', v_state.version,
    'players', v_players,
    'cards', v_cards,
    'score_tuwaiq', v_total - v_blue,
    'score_leap', v_total - v_red
  );
end;
$$;

-- ---------- إضافة لاعب: اللاعب اسم واحد لكل جهاز، الآدمن بدون حد ----------
create function public.game_add_player(p_device_id uuid, p_title text, p_player_name text, p_color text, p_admin_key text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_admin boolean := game_private.is_admin(p_admin_key);
begin
  if not v_admin then
    if p_device_id is null then
      raise exception 'device_required';
    end if;
    if exists (select 1 from public.game_players where device_id = p_device_id) then
      raise exception 'already_registered';
    end if;
  end if;

  begin
    insert into public.game_players (title, player_name, color, device_id)
    values (btrim(p_title), btrim(p_player_name), p_color, case when v_admin then null else p_device_id end);
  exception when unique_violation then
    raise exception 'already_registered';
  end;

  perform game_private.bump();
  return public.game_view(p_device_id, p_admin_key);
end;
$$;

-- ---------- حذف لاعب: الآدمن أي أحد، اللاعب اسمه هو، وقبل المباراة فقط ----------
create function public.game_remove_player(p_device_id uuid, p_player_id bigint, p_admin_key text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_admin boolean := game_private.is_admin(p_admin_key);
  v_phase text;
begin
  select phase into v_phase from public.game_state where id = 1 for update;
  if v_phase <> 'setup' then
    raise exception 'game_running';
  end if;

  if v_admin then
    delete from public.game_players where id = p_player_id;
  else
    delete from public.game_players
    where id = p_player_id and device_id is not null and device_id = p_device_id;
  end if;

  if found then
    perform game_private.bump();
  end if;
  return public.game_view(p_device_id, p_admin_key);
end;
$$;

-- ---------- تحكم الآدمن: start / reveal / end / setup ----------
create function public.game_admin(p_admin_key text, p_action text, p_card_id bigint default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_state public.game_state;
begin
  if not game_private.is_admin(p_admin_key) then
    raise exception 'not_admin';
  end if;

  select * into v_state from public.game_state where id = 1 for update;

  if p_action = 'start' then
    if not exists (select 1 from public.game_players) then
      raise exception 'no_players';
    end if;
    update public.game_state
    set phase = 'playing',
        card_ids = (select array_agg(id order by created_at, id) from public.game_players),
        revealed_ids = '{}'
    where id = 1;
  elsif p_action = 'reveal' then
    if v_state.phase = 'playing'
       and p_card_id = any(v_state.card_ids)
       and not (p_card_id = any(v_state.revealed_ids)) then
      update public.game_state set revealed_ids = array_append(revealed_ids, p_card_id) where id = 1;
    end if;
  elsif p_action = 'end' then
    if v_state.phase = 'playing' then
      update public.game_state set phase = 'ended' where id = 1;
    end if;
  elsif p_action = 'setup' then
    update public.game_state set phase = 'setup', card_ids = '{}', revealed_ids = '{}' where id = 1;
  else
    raise exception 'bad_action';
  end if;

  perform game_private.bump();
  return public.game_view(null, p_admin_key);
end;
$$;

revoke all on function public.game_view(uuid, text) from public;
revoke all on function public.game_add_player(uuid, text, text, text, text) from public;
revoke all on function public.game_remove_player(uuid, bigint, text) from public;
revoke all on function public.game_admin(text, text, bigint) from public;
grant execute on function public.game_view(uuid, text) to anon, authenticated;
grant execute on function public.game_add_player(uuid, text, text, text, text) to anon, authenticated;
grant execute on function public.game_remove_player(uuid, bigint, text) to anon, authenticated;
grant execute on function public.game_admin(text, text, bigint) to anon, authenticated;
