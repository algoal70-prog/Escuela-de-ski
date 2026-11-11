# COTA · Escuela de nieve

Agenda diaria de esquí y snowboard, con validación de clases, cupos, espera FIFO, alquileres, cierres por viento y honorarios. Español argentino, precios ARS de temporada 2026 y datos sintéticos.

**Estado:** proyecto propio Supabase Free creado y conectado. Tres cuentas de prueba activas, confirmadas y con roles exclusivos. Login por API, RLS y carreras de última plaza y última unidad verificados contra el servicio remoto el 11/11/2026. La contraseña de acceso se entrega en la conversación y no se publica en el repositorio. No se cargaron datos personales de terceros ni se contrataron servicios pagos.

## Probar en un minuto

Requiere Node.js 22 o superior.

```sh
npm ci
npm run build
npm run dev
```

Abrí `http://localhost:3000`. Sin variables, aparece **DEMO LOCAL**: PostgreSQL en el navegador (PGlite), con la misma función SQL de validación. Los cambios quedan en IndexedDB de ese navegador; no se comparten entre dispositivos. La demo tiene un perfil sintético fijo de coordinación, no autentica usuarios ni permite elegir roles. Día cargado: **14/08/2026**. Para reiniciar, borrá los datos del sitio en tu navegador.

## Conectar tu proyecto gratuito de Supabase

1. Creá un proyecto propio en Supabase, plan Free. En SQL Editor ejecutá, en orden: los archivos de `supabase/migrations/` en orden y después `supabase/seed.sql`. Ejecutalos una sola vez sobre una base nueva. **No ejecutes `scripts/demo-bootstrap.sql` ni `scripts/demo-profiles.sql` en Supabase**; son exclusivos de PGlite.
2. En Auth deshabilitá el registro público y la confirmación por correo. El frontend no tiene registro, recuperación ni envío de emails. `supabase/config.toml` expresa esos valores para desarrollo con Supabase CLI.
3. Copiá `.env.example` como `.env` y reemplazá los valores ficticios. `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` son públicos. `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` y `DEMO_PASSWORD` se usan **solo en terminal**, para crear cuentas de prueba. La clave service role nunca se incluye en el build.
4. Ejecutá `npm run seed:auth`. El script crea usuarios confirmados con la API administrativa, asigna sus perfiles desde la base y vincula al instructor Lara Lagos. No manda correos. Las claves existentes no se cambian al repetir el script.
5. Ejecutá `node --env-file=.env scripts/build.mjs` y `npm run dev`. Publicá el contenido de `dist/` en un hosting estático para compartir el acceso. Las variables de build deben conservarse en tu proveedor de despliegue.

| Cuenta de prueba | Rol | Acceso |
| --- | --- | --- |
| `coordinacion@cota.test` | Coordinación | Toda la operación y finanzas |
| `recepcion@cota.test` | Recepción | Alumnos, clases, inscripciones y equipos |
| `instructor@cota.test` | Instructor | Clases de Lara Lagos y marcar dictadas |

**Contraseña:** el valor de `DEMO_PASSWORD` que definiste localmente. Las cuentas de la instalación entregada ya existen; en una instalación nueva, estarán disponibles al completar el paso 4.

## Cómo funciona

- **Una sola regla de verdad:** `validate_class(jsonb, uuid)` devuelve `{code,message}[]`. La usan nueva clase, edición, inscripción y propuestas de viento. Capacidad por eventos de inicio/fin, intervalos `[inicio, fin)`, margen de 30 minutos y tope de 6 horas. Día completo: 10–16, almuerzo 13–14, **5 horas efectivas**.
- **Operación atómica:** `mutate(action,p,request_id)` valida dentro de PostgreSQL y usa un bloqueo transaccional de la escuela. Serializa las operaciones sobre cupo, agenda y stock; idempotencia por usuario/request y versiones para rechazar datos viejos. Nunca se resta un contador en el navegador: cupo y stock se calculan desde registros activos.
- **RLS en las 13 tablas.** El navegador tiene SELECT limitado y RPC; no puede escribir directamente. Una cuenta tiene un rol en `profiles`, sin autoasignación ni cambio público. Finanzas y honorarios solo para coordinación; instructor solo accede a clases propias y sus alumnos. Anónimo no tiene catálogos privados ni RPC.
- **Viento:** alternativas en el mismo horario, sectores exteriores primero, refugio después y finalmente otros horarios con el mismo instructor. Cada opción se descarta o acepta y se revalida al guardar.
- **Grupales:** 8 lugares por fecha, edad mínima 16, máximo dos niveles consecutivos. Espera FIFO con aviso listo para compartir al promover. El aviso no se envía solo. A las 18 de la víspera, con menos de 3, el estado visible pasa a Por revisar al consultar la app, sin tareas programadas. Se pueden fusionar o cancelar desde coordinación.
- **Dinero:** cobro manual pagado/pendiente. Honorarios solo de dictadas: exclusiva 35%, semi 30%, grupal $18.000 por presente. Facturación de clases excluye canceladas; el cobrado se muestra separado. WhatsApp abre el texto para compartir; recuerda llegar 90 minutos antes. Sin pagos, mapas ni emails.

## Pruebas

```sh
npm test
```

**22 pruebas automáticas** ejecutan las migraciones y RPC reales sobre PostgreSQL embebido (PGlite), incluyendo RLS con los roles `anon` y `authenticated`, cambio de identificadores, inmutabilidad de dictadas, stock, idempotencia, versión vieja, espera FIFO, intervalos, idiomas y habilitaciones. PGlite no sustituye una prueba con varias conexiones de PostgreSQL remoto. Después de conectar Supabase y crear las cuentas, `npm run test:remote` verifica el login de los tres roles, el aislamiento por IDs y dos solicitudes simultáneas para la última plaza y la última unidad. Ese ensayo remoto pasó contra el proyecto entregado; crea registros sintéticos y cancela sus reservas al terminar.

## Archivos principales

| Ruta | Contenido |
| --- | --- |
| `web/` | Interfaz responsive y adaptador Supabase Auth/REST |
| `supabase/migrations/` | Esquema, RLS, validador y operaciones atómicas |
| `supabase/seed.sql` | 10 instructores, 40 alumnos, 6 sectores, precios y jornada |
| `scripts/seed-auth.mjs` | Alta administrativa de cuentas de prueba |
| `tests/` | Pruebas funcionales y de autorización |
| `.env.example` | Nombres y valores ficticios, sin secretos |

Identidad: Archivo + Inter; azul glaciar y blanco nieve. Naranja reservado para cierres y conflictos. No usar información personal real en esta instalación de prueba.

## Revisión de seguridad

El asesor de Supabase detecta RPC con `SECURITY DEFINER` accesibles a usuarios autenticados. Es intencional: `mutate`, el validador y las consultas limitadas comprueban `auth.uid()` y el rol, usan `search_path` fijo y revocan el acceso anónimo. No hay escrituras directas del navegador. Los ayudantes de rol solo devuelven información de la sesión o pertenencia propia. [Referencia del asesor](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable).

La protección adicional de contraseñas filtradas no está habilitada en este proyecto gratuito. La instalación contiene exclusivamente cuentas y datos sintéticos. [Referencia de Supabase](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

La pantalla no ofrece alta pública ni recuperación. Para replicar una instalación cerrada, deshabilitá también el registro público en el panel de Auth; las cuentas preconfirmadas no necesitan enviar ni confirmar correos.
