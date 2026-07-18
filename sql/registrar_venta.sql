-- ============================================================================
-- Mini Encanto — RPC transaccional de venta
-- ----------------------------------------------------------------------------
-- Registra una venta completa en UNA sola transacción atómica:
--   1. Cabecera de la venta (tabla ventas)
--   2. Descuento de stock de cada variante (con bloqueo de fila)
--   3. Registro de movimientos (tipo = 'venta')
--   4. Detalle de items (tabla items_ventas)
--   5. Actualización de saldo de cuenta corriente (si corresponde)
--
-- Si CUALQUIER paso falla, se revierte TODO (no quedan ventas a medias).
-- El número de ticket se asigna sin condición de carrera (advisory lock) y el
-- stock se descuenta con SELECT ... FOR UPDATE para que dos ventas simultáneas
-- no lean el mismo stock y se pisen.
--
-- El total se calcula en el servidor a partir de los items: no se confía en el
-- total que manda el cliente.
--
-- Cómo aplicar: pegar este archivo en Supabase → SQL Editor → Run.
-- ============================================================================

create or replace function public.registrar_venta(
  p_cliente_id      text,      -- id del cliente (null = consumidor final)
  p_cliente_nombre  text,
  p_cliente_tel     text,
  p_pago            text,      -- ej. 'Efectivo' o 'Efectivo + Cuenta cte.'
  p_tipo_precio     text,      -- 'minorista' | 'mayorista'
  p_descuento       numeric,   -- monto de descuento ya calculado
  p_descuento_tipo  text,
  p_usuario         text,
  p_monto_cta       numeric,   -- cuánto de esta venta va a cuenta corriente (0 = nada)
  p_items           jsonb      -- [{variante_id, producto_id, nombre, talle, precio, qty}, ...]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_num       integer;
  v_fecha     timestamptz := now();
  v_subtotal  numeric := 0;
  v_total     numeric;
  v_item      jsonb;
  v_var_id    text;
  v_qty       numeric;
  v_precio    numeric;
  v_stock     numeric;
  v_nuevo     numeric;
  v_saldo     numeric;
begin
  -- 0) Validación mínima
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta no tiene items';
  end if;

  -- 1) Número de ticket sin condición de carrera.
  --    El advisory lock (por transacción) serializa la numeración entre ventas
  --    concurrentes; se libera solo al terminar la transacción.
  perform pg_advisory_xact_lock(hashtext('mini_encanto_venta_num'));
  select coalesce(max(num), 1000) + 1 into v_num from ventas;

  -- 2) Subtotal y total calculados en el servidor
  for v_item in select value from jsonb_array_elements(p_items) as t(value) loop
    v_subtotal := v_subtotal
      + (coalesce((v_item->>'precio')::numeric, 0)
       * coalesce((v_item->>'qty')::numeric, 0));
  end loop;
  v_total := v_subtotal - coalesce(p_descuento, 0);

  -- 3) Cabecera de la venta
  insert into ventas (num, fecha, cliente, cliente_tel, pago, tipo_precio,
                      total, descuento, descuento_tipo, usuario)
  values (v_num, v_fecha, p_cliente_nombre, p_cliente_tel, p_pago, p_tipo_precio,
          v_total, coalesce(p_descuento, 0), p_descuento_tipo, p_usuario);

  -- 4) Por cada item: descontar stock (con bloqueo), registrar movimiento y detalle
  for v_item in select value from jsonb_array_elements(p_items) as t(value) loop
    v_var_id := v_item->>'variante_id';
    v_qty    := coalesce((v_item->>'qty')::numeric, 0);
    v_precio := coalesce((v_item->>'precio')::numeric, 0);

    if v_var_id is not null and v_var_id <> '' then
      -- Bloqueo de fila: dos ventas simultáneas no pueden leer el mismo stock
      select stock into v_stock from variantes where id = v_var_id for update;
      if not found then
        raise exception 'Variante inexistente: %', v_var_id;
      end if;

      -- Se mantiene la política actual: el stock nunca baja de 0 (permite vender
      -- aunque el conteo esté en 0). Para bloquear la venta por falta de stock,
      -- reemplazar por: if coalesce(v_stock,0) < v_qty then raise exception ...
      v_nuevo := greatest(0, coalesce(v_stock, 0) - v_qty);
      update variantes set stock = v_nuevo where id = v_var_id;

      insert into movimientos (tipo, producto, talle, qty, motivo, usuario, fecha)
      values ('venta', v_item->>'nombre', v_item->>'talle', v_qty,
              'Venta #' || v_num, p_usuario, v_fecha);
    end if;

    insert into items_ventas (venta_num, producto_id, nombre, talle, precio, qty)
    values (v_num, v_item->>'producto_id', v_item->>'nombre',
            v_item->>'talle', v_precio, v_qty);
  end loop;

  -- 5) Cuenta corriente (con bloqueo de fila del cliente)
  if p_cliente_id is not null and p_cliente_id <> '' and coalesce(p_monto_cta, 0) > 0 then
    select saldo into v_saldo from clientes where id = p_cliente_id for update;
    if found then
      update clientes set saldo = coalesce(v_saldo, 0) + p_monto_cta
      where id = p_cliente_id;
    end if;
  end if;

  return jsonb_build_object('num', v_num, 'fecha', v_fecha, 'total', v_total);
end;
$$;

-- Permisos: la app usa usuarios autenticados de Supabase Auth.
-- SECURITY DEFINER + este grant permiten que la venta escriba aunque las tablas
-- tengan RLS restrictiva, sin exponer INSERT/UPDATE directos a los clientes.
revoke all on function public.registrar_venta(
  text, text, text, text, text, numeric, text, text, numeric, jsonb) from public;
grant execute on function public.registrar_venta(
  text, text, text, text, text, numeric, text, text, numeric, jsonb) to authenticated;
