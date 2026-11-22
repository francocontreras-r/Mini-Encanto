-- ============================================================================
-- Mini Encanto — Etapa B: Seguridad real por rol (RLS)
-- ----------------------------------------------------------------------------
-- Reemplaza la política única "cualquier logueado puede todo" por permisos
-- reales según el rol (admin / vendedor / contador), aplicados EN LA BASE.
--
--   • Admin    → todo.
--   • Vendedor → vender/cobrar, caja (abrir/cerrar/mov.), clientes (crear/cobrar),
--                y LEER todo. No borra/edita productos, no cambia precios,
--                no da bajas ni ingresos de stock, no administra usuarios.
--   • Contador → solo lectura.
--
-- La venta NO se rompe: registrar_venta es SECURITY DEFINER y sigue
-- descontando stock / numerando ticket / actualizando cuenta corriente.
--
-- Pegar COMPLETO en Supabase → SQL Editor → Run. Es idempotente.
-- ============================================================================

-- ⚠️ PASO 0 — IMPORTANTÍSIMO (hacelo ANTES de seguir):
-- Asegurate de que TU usuario quede como admin, o perderías el acceso de
-- administración. Reemplazá el email por el tuyo y corré ESTA línea sola primero:
--
--   insert into public.usuarios_roles (email, rol)
--   values ('TU-EMAIL-DE-LOGIN@ejemplo.com', 'admin')
--   on conflict (email) do update set rol = 'admin';
--
-- (Si ya figurás como admin en usuarios_roles, igual no está de más correrla.)
-- ----------------------------------------------------------------------------

-- 1) Función que devuelve el rol del usuario actual.
--    SECURITY DEFINER para poder leer usuarios_roles sin chocar con RLS.
--    Si el usuario no tiene rol asignado, se asume 'vendedor' (mínimo operativo).
create or replace function public.mi_rol()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select rol from public.usuarios_roles
      where email = (auth.jwt() ->> 'email') limit 1),
    'vendedor'
  );
$$;
grant execute on function public.mi_rol() to authenticated;

-- 2) Habilitar RLS y limpiar políticas anteriores en todas las tablas.
do $$
declare
  t text;
  tablas text[] := array[
    'bajas','cajas','clientes','historial_precios','items_ventas',
    'movimientos','movimientos_caja','productos','usuarios_app',
    'usuarios_roles','variantes','ventas'
  ];
begin
  foreach t in array tablas loop
    if to_regclass('public.'||t) is null then
      raise notice 'Tabla % no existe, se omite.', t; continue;
    end if;
    execute format('alter table public.%I enable row level security;', t);
    -- quitar la política permisiva anterior y cualquier política de esta migración
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_auth_all', t);
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_sel', t);
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_wadmin', t);
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_ins', t);
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_upd', t);
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_del', t);
    -- LECTURA: todos los autenticados (admin, vendedor, contador) pueden leer
    execute format('create policy %I on public.%I for select to authenticated using (true);', 'me_'||t||'_sel', t);
  end loop;
end $$;

-- 3) ESCRITURA SOLO ADMIN (productos, precios, stock, ventas pasadas, usuarios…)
do $$
declare
  t text;
  tablas text[] := array[
    'bajas','historial_precios','items_ventas','movimientos',
    'productos','usuarios_app','usuarios_roles','variantes','ventas'
  ];
begin
  foreach t in array tablas loop
    if to_regclass('public.'||t) is null then continue; end if;
    execute format(
      'create policy %I on public.%I for all to authenticated using (public.mi_rol()=''admin'') with check (public.mi_rol()=''admin'');',
      'me_'||t||'_wadmin', t);
  end loop;
end $$;

-- 4) CAJAS y CLIENTES: crear/editar → admin o vendedor; borrar → solo admin.
do $$
declare
  t text;
  tablas text[] := array['cajas','clientes'];
begin
  foreach t in array tablas loop
    if to_regclass('public.'||t) is null then continue; end if;
    execute format('create policy %I on public.%I for insert to authenticated with check (public.mi_rol() in (''admin'',''vendedor''));', 'me_'||t||'_ins', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.mi_rol() in (''admin'',''vendedor'')) with check (public.mi_rol() in (''admin'',''vendedor''));', 'me_'||t||'_upd', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.mi_rol()=''admin'');', 'me_'||t||'_del', t);
  end loop;
end $$;

-- 5) MOVIMIENTOS_CAJA: registrar (insert) → admin o vendedor; editar/borrar → admin.
create policy me_movimientos_caja_ins on public.movimientos_caja
  for insert to authenticated with check (public.mi_rol() in ('admin','vendedor'));
create policy me_movimientos_caja_upd on public.movimientos_caja
  for update to authenticated using (public.mi_rol()='admin') with check (public.mi_rol()='admin');
create policy me_movimientos_caja_del on public.movimientos_caja
  for delete to authenticated using (public.mi_rol()='admin');

-- ----------------------------------------------------------------------------
-- VERIFICACIÓN (opcional): ver las políticas creadas
--   select tablename, policyname, cmd, roles
--   from pg_policies where schemaname='public' order by tablename, policyname;
--
-- Probá con un usuario VENDEDOR: debe poder registrar una venta y abrir/cerrar
-- caja, pero NO borrar un producto ni cambiar precios.
-- ============================================================================
-- ROLLBACK (volver a "cualquier logueado puede todo", por si algo molesta):
--
-- do $$
-- declare t text; tablas text[] := array[
--   'bajas','cajas','clientes','historial_precios','items_ventas','movimientos',
--   'movimientos_caja','productos','usuarios_app','usuarios_roles','variantes','ventas'];
-- begin
--   foreach t in array tablas loop
--     if to_regclass('public.'||t) is null then continue; end if;
--     execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_sel', t);
--     execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_wadmin', t);
--     execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_ins', t);
--     execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_upd', t);
--     execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_del', t);
--     execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_auth_all', t);
--     execute format('create policy %I on public.%I for all to authenticated using (true) with check (true);', 'me_'||t||'_auth_all', t);
--   end loop;
-- end $$;
-- ============================================================================
