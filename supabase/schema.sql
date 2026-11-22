-- =====================================================================
--  매일 뇌운동 · Supabase 데이터베이스 설정
--  Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여넣고 [Run] 하세요.
--  여러 번 실행해도 안전하게 만들었습니다.
-- =====================================================================

-- 1) 프로필: 닉네임과 친구 코드 -------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  nickname    text not null default '뇌운동 친구' check (char_length(nickname) between 1 and 12),
  friend_code text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  created_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "profiles: 내 것 읽기" on public.profiles;
create policy "profiles: 내 것 읽기" on public.profiles for select using (auth.uid() = id);
drop policy if exists "profiles: 내 것 수정" on public.profiles;
create policy "profiles: 내 것 수정" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- 가입하면 프로필 자동 생성 (카카오 닉네임 → 가입 때 쓴 닉네임 → 이메일 앞부분 순서)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nickname)
  values (new.id, left(coalesce(
    nullif(new.raw_user_meta_data->>'nickname', ''),
    nullif(new.raw_user_meta_data->>'name', ''),
    nullif(new.raw_user_meta_data->>'user_name', ''),
    nullif(new.raw_user_meta_data->>'full_name', ''),
    nullif(new.raw_user_meta_data->>'preferred_username', ''),
    nullif(split_part(new.email, '@', 1), ''),
    '뇌운동 친구'), 12))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2) 기기 사이 기록 이어하기 (최고 점수·능력치·포인트 묶음) ---------------
create table if not exists public.user_state (
  user_id    uuid primary key references auth.users on delete cascade,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.user_state enable row level security;
drop policy if exists "user_state: 내 것만" on public.user_state;
create policy "user_state: 내 것만" on public.user_state for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 3) 게임 점수 (순위용) ---------------------------------------------------
create table if not exists public.scores (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  game_id    text not null check (char_length(game_id) <= 20),
  score      int  not null check (score between 0 and 100000),
  created_at timestamptz not null default now()
);
create index if not exists scores_game_score on public.scores (game_id, score desc);
create index if not exists scores_user_game on public.scores (user_id, game_id);
alter table public.scores enable row level security;
drop policy if exists "scores: 내 점수 쓰기" on public.scores;
create policy "scores: 내 점수 쓰기" on public.scores for insert with check (auth.uid() = user_id);
drop policy if exists "scores: 내 점수 읽기" on public.scores;
create policy "scores: 내 점수 읽기" on public.scores for select using (auth.uid() = user_id);

-- 4) 출석 체크 (한국 시간 기준 하루 한 번) -------------------------------
create table if not exists public.attendance (
  user_id uuid not null references auth.users on delete cascade,
  day     date not null,
  primary key (user_id, day)
);
alter table public.attendance enable row level security;
drop policy if exists "attendance: 내 것 읽기" on public.attendance;
create policy "attendance: 내 것 읽기" on public.attendance for select using (auth.uid() = user_id);

create or replace function public.check_in() returns json
language plpgsql security definer set search_path = public as $$
declare d date := (now() at time zone 'Asia/Seoul')::date; ins int; s int := 0; x date := d; recent date[];
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  insert into attendance (user_id, day) values (auth.uid(), d) on conflict do nothing;
  get diagnostics ins = row_count;
  loop
    exit when not exists (select 1 from attendance where user_id = auth.uid() and day = x);
    s := s + 1; x := x - 1;
  end loop;
  select array_agg(day order by day) into recent from attendance where user_id = auth.uid() and day > d - 7;
  return json_build_object('today', d, 'is_new', ins > 0, 'streak', s, 'recent', coalesce(recent, '{}'::date[]));
end $$;

-- 5) 친구 (코드로 추가하면 서로 친구) -------------------------------------
create table if not exists public.friends (
  user_id    uuid not null references auth.users on delete cascade,
  friend_id  uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
alter table public.friends enable row level security;
drop policy if exists "friends: 내 것 읽기" on public.friends;
create policy "friends: 내 것 읽기" on public.friends for select using (auth.uid() = user_id);

create or replace function public.add_friend(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare fid uuid; nm text;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  select id, nickname into fid, nm from profiles where friend_code = upper(trim(p_code));
  if fid is null then raise exception '친구 코드를 찾을 수 없어요'; end if;
  if fid = auth.uid() then raise exception '내 코드는 추가할 수 없어요'; end if;
  if (select count(*) from friends where user_id = auth.uid()) >= 100 then raise exception '친구는 100명까지예요'; end if;
  insert into friends values (auth.uid(), fid, now()) on conflict do nothing;
  insert into friends values (fid, auth.uid(), now()) on conflict do nothing;
  return nm;
end $$;

create or replace function public.remove_friend(p_friend uuid) returns void
language sql security definer set search_path = public as $$
  delete from friends where (user_id = auth.uid() and friend_id = p_friend) or (user_id = p_friend and friend_id = auth.uid());
$$;

create or replace function public.my_friends() returns table (id uuid, nickname text)
language sql stable security definer set search_path = public as $$
  select p.id, p.nickname from friends f join profiles p on p.id = f.friend_id
  where f.user_id = auth.uid() order by p.nickname;
$$;

-- 6) 순위 (게임별 최고 점수, 전체 또는 친구) -------------------------------
create or replace function public.leaderboard(p_game text, p_friends boolean default false)
returns table (rank bigint, nickname text, best int, is_me boolean)
language sql stable security definer set search_path = public as $$
  with b as (
    select s.user_id, max(s.score) as best from scores s
    where s.game_id = p_game
      and (not p_friends or s.user_id = auth.uid()
           or s.user_id in (select friend_id from friends where user_id = auth.uid()))
    group by s.user_id
  ), r as (
    select rank() over (order by b.best desc) as rank, coalesce(p.nickname, '뇌운동 친구') as nickname,
           b.best, b.user_id = auth.uid() as is_me
    from b left join profiles p on p.id = b.user_id
  )
  -- 상위 50명 + (50위 밖이어도) 내 순위
  select * from r where rank <= 50 or is_me order by rank, is_me desc;
$$;

-- 7) 계정 삭제 (본인만) ----------------------------------------------------
create or replace function public.delete_me() returns void
language sql security definer set search_path = public as $$
  delete from auth.users where id = auth.uid();
$$;

-- 함수 권한: 로그인한 사용자만 실행
revoke all on function public.check_in(), public.add_friend(text), public.remove_friend(uuid),
  public.my_friends(), public.leaderboard(text, boolean), public.delete_me() from public, anon;
grant execute on function public.check_in(), public.add_friend(text), public.remove_friend(uuid),
  public.my_friends(), public.leaderboard(text, boolean), public.delete_me() to authenticated;

-- 8) 테이블 사용 권한 (새 Supabase 프로젝트는 자동으로 주지 않아요) --------
grant usage on schema public to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.user_state to authenticated;
grant select, insert on public.scores to authenticated;
grant select on public.attendance, public.friends to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- 9) 순위 한눈에 보기: 게임마다 1위와 내 순위를 한 번에 ---------------------
create or replace function public.leaderboard_summary(p_friends boolean default false)
returns table (game_id text, top_nickname text, top_best int, my_best int, my_rank bigint, players bigint)
language sql stable security definer set search_path = public as $$
  with b as (
    select s.game_id, s.user_id, max(s.score) as best from scores s
    where (not p_friends or s.user_id = auth.uid()
           or s.user_id in (select friend_id from friends where user_id = auth.uid()))
    group by s.game_id, s.user_id
  ), r as (
    select b.*, rank() over (partition by b.game_id order by b.best desc) as rk,
           count(*) over (partition by b.game_id) as n
    from b
  )
  select g.game_id, t.nickname, t.best, m.best, m.rk, g.n
  from (select distinct on (r.game_id) r.game_id, r.n from r order by r.game_id) g
  left join lateral (
    select coalesce(p.nickname, '뇌운동 친구') as nickname, r.best from r left join profiles p on p.id = r.user_id
    where r.game_id = g.game_id and r.rk = 1 order by p.nickname limit 1) t on true
  left join lateral (select r.best, r.rk from r where r.game_id = g.game_id and r.user_id = auth.uid()) m on true;
$$;
revoke all on function public.leaderboard_summary(boolean) from public, anon;
grant execute on function public.leaderboard_summary(boolean) to authenticated;
