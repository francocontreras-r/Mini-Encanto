-- ============================================================================
-- Mini Encanto — Row Level Security (RLS)
-- ----------------------------------------------------------------------------
-- Activa RLS en todas las tablas y deja una política base: SOLO usuarios
-- AUTENTICADOS (logueados por Supabase Auth) pueden leer/escribir. El acceso
-- anónimo (con la anon key pero SIN sesión iniciada) queda bloqueado.
--
-- POR QUÉ IMPORTA: la anon key está a la vista en el index.html (se ve con
-- "ver código fuente"). Sin RLS, cualquiera en internet con esa clave podría
-- leer, modificar o borrar toda la base SIN loguearse. Con RLS activo, hay que
-- estar logueado para tocar los datos.
--
-- COMPATIBILIDAD:
--   - La app sigue funcionando igual: todos los usuarios reales están logueados
--     (authenticated), así que conservan acceso completo.
--   - registrar_venta (SECURITY DEFINER) se salta RLS por diseño: la venta
--     transaccional NO se ve afectada.
--   - El panel de Supabase (service_role) también se salta RLS.
--
-- Cómo aplicar: pegar este archivo COMPLETO en Supabase → SQL Editor → Run.
-- Es idempotente: se puede correr las veces que haga falta.
-- ============================================================================

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
    -- Si alguna tabla se llama distinto o no existe, se omite sin romper todo.
    if to_regclass('public.'||t) is null then
      raise notice 'Tabla % no existe en public, se omite.', t;
      continue;
    end if;

    execute format('alter table public.%I enable row level security;', t);
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_auth_all', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (true) with check (true);',
      'me_'||t||'_auth_all', t
    );
  end loop;
end $$;

-- Verificación rápida (opcional): RLS activado en cada tabla.
--   select tablename, rowsecurity as rls_activado
--   from pg_tables where schemaname = 'public' order by tablename;
--
-- Y las políticas creadas:
--   select tablename, policyname, roles, cmd
--   from pg_policies where schemaname = 'public' order by tablename;
