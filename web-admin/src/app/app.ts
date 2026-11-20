import { Component, computed, HostListener, inject, signal } from '@angular/core';
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { filter } from 'rxjs';
import { EstadoSistema } from './core/api';
import { AuthService, NOMBRE_ROL, Rol } from './core/auth';
import { Campana } from './core/campana';

interface Enlace { ruta: string; texto: string; roles: Rol[] }
interface Grupo { titulo: string; enlaces: Enlace[] }

/** Menú por secciones: si una sección tiene más de una opción para el rol, se muestra como submenú. */
const MENU: Grupo[] = [
  { titulo: 'Inicio', enlaces: [{ ruta: '/inicio', texto: 'Inicio', roles: ['LABORATORISTA', 'MEDICO', 'ADMIN'] }] },
  {
    titulo: 'Atención', enlaces: [
      { ruta: '/agenda', texto: 'Agenda del día', roles: ['LABORATORISTA', 'MEDICO', 'ADMIN'] },
      { ruta: '/horario', texto: 'Mi horario', roles: ['MEDICO'] },
      { ruta: '/horario', texto: 'Horarios de médicos', roles: ['ADMIN'] },
      { ruta: '/solicitudes', texto: 'Solicitudes y resultados', roles: ['LABORATORISTA', 'MEDICO', 'ADMIN'] },
      { ruta: '/nueva-solicitud', texto: 'Nueva solicitud', roles: ['LABORATORISTA', 'MEDICO'] },
    ],
  },
  {
    titulo: 'Pacientes', enlaces: [
      { ruta: '/pacientes', texto: 'Pacientes y tratamientos', roles: ['MEDICO'] },
      // El laboratorio y la administración ven solo los datos y los exámenes del paciente, no sus tratamientos.
      { ruta: '/pacientes', texto: 'Pacientes', roles: ['ADMIN', 'LABORATORISTA'] },
    ],
  },
  {
    titulo: 'Catálogo y sucursales', enlaces: [
      { ruta: '/catalogo', texto: 'Exámenes', roles: ['ADMIN'] },
      { ruta: '/sucursales', texto: 'Sucursales y laboratorios', roles: ['ADMIN'] },
      { ruta: '/franjas', texto: 'Turnos de toma de muestras', roles: ['ADMIN'] },
      { ruta: '/descuentos', texto: 'Descuentos', roles: ['ADMIN'] },
    ],
  },
  {
    titulo: 'Base de conocimientos', enlaces: [
      { ruta: '/conocimiento/reglas', texto: 'Reglas diagnósticas', roles: ['ADMIN'] },
      { ruta: '/conocimiento/diagnosticos', texto: 'Diagnósticos y protocolos', roles: ['ADMIN'] },
      { ruta: '/conocimiento/medicamentos', texto: 'Medicamentos', roles: ['ADMIN'] },
    ],
  },
  {
    titulo: 'Administración', enlaces: [
      { ruta: '/usuarios', texto: 'Usuarios y roles', roles: ['ADMIN'] },
      { ruta: '/pagos', texto: 'Pagos y reembolsos', roles: ['ADMIN'] },
      { ruta: '/reportes', texto: 'Reportes', roles: ['ADMIN', 'MEDICO'] },
      { ruta: '/auditoria', texto: 'Auditoría y correos', roles: ['ADMIN'] },
    ],
  },
];

@Component({
  selector: 'app-root',
  imports: [RouterOutlet, RouterLink, RouterLinkActive, Campana],
  template: `
    @if (auth.autenticado()) {
      <div class="marco" [class]="'marco rol-' + auth.rolActivo()">
        <aside class="lateral">
          <div class="marca">
            <span class="logo" aria-hidden="true">+</span>
            <div><strong>Laboratorio Clínico</strong><small>Portal de {{ portal[auth.rolActivo()!] }}</small></div>
          </div>
          <nav>
            @for (g of menu(); track g.titulo) {
              @if (g.enlaces.length === 1) {
                <a [routerLink]="g.enlaces[0].ruta" routerLinkActive="activo">{{ g.enlaces[0].texto }}</a>
              } @else {
                <button type="button" class="grupo" [attr.aria-expanded]="abierto(g.titulo)" (click)="alternarGrupo(g.titulo)">
                  {{ g.titulo }} <span class="flecha">{{ abierto(g.titulo) ? '−' : '+' }}</span>
                </button>
                @if (abierto(g.titulo)) {
                  <div class="sub">
                    @for (e of g.enlaces; track e.ruta + e.texto) {
                      <a [routerLink]="e.ruta" routerLinkActive="activo">{{ e.texto }}</a>
                    }
                  </div>
                }
              }
            }
          </nav>
          <div class="pie-lateral">
            @if (estado.instancia()) {
              <small>Atendido por {{ estado.instancia() }}{{ estado.vm() ? ' · ' + estado.vm() : '' }}</small>
            }
          </div>
        </aside>
        <div class="principal">
          <header class="cabecera">
            <div>
              <strong>{{ auth.usuario()?.nombre }}</strong>
              <small class="muted">{{ auth.usuario()?.email }}</small>
            </div>
            <div class="acciones">
              <app-campana />
              <span class="badge-rol">{{ nombreRol[auth.rolActivo()!] }}</span>
              @if (auth.rolesDisponibles().length > 1) {
                <button class="secundario chico" (click)="eligiendo.set(true)">Cambiar de rol</button>
              }
              <button class="secundario chico" (click)="auth.logout()">Salir</button>
            </div>
          </header>
          @if (estado.origenDatos() === 'supabase') {
            <div class="contingencia">
              Modo contingencia: la base principal no está disponible. Los datos se leen de la réplica (Supabase)
              y las operaciones de escritura están deshabilitadas temporalmente.
            </div>
          }
          <main><router-outlet /></main>
          @if (abajo()) {
            <button type="button" class="subir" (click)="subir()" aria-label="Volver arriba" title="Volver arriba">&#8593;</button>
          }
        </div>
      </div>
      @if (eligiendo()) {
        <div class="velo" (click)="eligiendo.set(false)">
          <div class="card modal" (click)="$event.stopPropagation()" role="dialog" aria-label="Cambiar de rol">
            <h2>¿Con qué rol desea trabajar?</h2>
            @for (r of auth.rolesDisponibles(); track r) {
              <button class="opcion" [class]="'opcion rol-' + r" [disabled]="r === auth.rolActivo()" (click)="cambiar(r)">
                <span class="punto"></span>{{ nombreRol[r] }}
                @if (r === auth.rolActivo()) { <small>actual</small> }
                @if (r === 'PACIENTE') { <small>abre el portal de pacientes</small> }
              </button>
            }
            <button class="secundario chico" (click)="eligiendo.set(false)">Cancelar</button>
          </div>
        </div>
      }
    } @else {
      <router-outlet />
    }
  `,
  styles: `
    .marco { display: grid; grid-template-columns: 240px 1fr; min-height: 100vh; }
    .lateral { background: var(--verde-oscuro); color: #fff; display: flex; flex-direction: column; position: sticky; top: 0; height: 100vh; }
    .marca { display: flex; gap: 10px; align-items: center; padding: 18px 16px; border-bottom: 1px solid rgb(255 255 255 / 12%); }
    .marca small { display: block; opacity: .75; font-size: 12px; }
    .logo { width: 34px; height: 34px; border-radius: 8px; background: #fff; color: var(--verde); font-size: 28px;
            font-weight: 800; display: grid; place-items: center; line-height: 1; }
    .grupo { display: flex; justify-content: space-between; width: 100%; background: none; border: 0; color: #fff;
             padding: 9px 12px; font-weight: 600; text-align: left; border-radius: 6px; cursor: pointer; }
    .grupo:hover { background: rgb(255 255 255 / 10%); }
    .flecha { opacity: .7; }
    .sub { display: flex; flex-direction: column; gap: 2px; margin: 0 0 6px 10px; border-left: 1px solid rgb(255 255 255 / 20%); padding-left: 4px; }
    .subir { position: fixed; right: 24px; bottom: 24px; width: 46px; height: 46px; border-radius: 50%; font-size: 22px;
             box-shadow: 0 2px 10px rgb(0 0 0 / 25%); z-index: 30; padding: 0; }
    nav { display: flex; flex-direction: column; padding: 10px 8px; gap: 2px; overflow-y: auto; }
    nav a { color: #e6f2ee; text-decoration: none; padding: 9px 12px; border-radius: 6px; }
    nav a:hover { background: rgb(255 255 255 / 10%); }
    nav a.activo { background: #fff; color: var(--verde-oscuro); font-weight: 600; }
    .pie-lateral { margin-top: auto; padding: 12px 16px; opacity: .7; font-size: 12px; }
    .principal { min-width: 0; }
    .cabecera { background: #fff; border-bottom: 1px solid var(--borde); padding: 12px 24px; display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
    .cabecera small { display: block; }
    .acciones { display: flex; gap: 12px; align-items: center; }
    .rol { display: flex; gap: 8px; align-items: center; font-size: 13px; color: var(--gris); }
    .badge-rol { background: var(--verde); color: #fff; border-radius: 20px; padding: 3px 12px; font-size: 12px; font-weight: 600; }
    .velo { position: fixed; inset: 0; background: rgb(0 0 0 / 35%); display: grid; place-items: center; z-index: 50; padding: 16px; }
    .modal { width: min(380px, 100%); display: flex; flex-direction: column; gap: 8px; }
    .opcion { display: flex; align-items: center; gap: 10px; justify-content: flex-start; width: 100%;
              background: #fff; color: var(--tinta); border: 1px solid var(--borde); padding: 12px; }
    .opcion:hover:not(:disabled) { border-color: var(--verde); background: var(--verde-suave); }
    .opcion small { margin-left: auto; color: var(--gris); }
    .punto { width: 14px; height: 14px; border-radius: 50%; background: var(--verde); }
    .contingencia { background: var(--ambar-suave); color: var(--ambar); border-bottom: 1px solid #f0d68a; padding: 10px 24px; font-weight: 600; }
    main { padding: 24px; max-width: 1200px; }
    @media (max-width: 860px) {
      /* El menú arriba ocupa solo su alto; antes la fila se estiraba hasta llenar la pantalla. */
      .marco { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
      .lateral { position: static; height: auto; }
      nav { flex-direction: row; flex-wrap: wrap; }
      .grupo { width: auto; }
      .sub { flex-direction: row; flex-wrap: wrap; margin: 0; border: 0; }
      main { padding: 16px; }
    }
  `,
})
export class App {
  protected readonly auth = inject(AuthService);
  protected readonly estado = inject(EstadoSistema);
  protected readonly nombreRol = NOMBRE_ROL;
  protected readonly portal: Record<Rol, string> = {
    PACIENTE: 'pacientes', LABORATORISTA: 'laboratorio', MEDICO: 'médicos', ADMIN: 'administración',
  };
  protected readonly eligiendo = signal(false);
  private readonly router = inject(Router);
  private readonly abiertos = signal(new Set<string>());
  /** Botón para volver arriba cuando la pantalla tiene mucho contenido. */
  protected readonly abajo = signal(false);

  constructor() {
    // Se abre solo el submenú de la página actual.
    this.router.events.pipe(filter((e) => e instanceof NavigationEnd)).subscribe((e) => {
      const url = (e as NavigationEnd).urlAfterRedirects;
      const grupo = MENU.find((g) => g.enlaces.length > 1 && g.enlaces.some((x) => url.startsWith(x.ruta)));
      if (grupo) this.abiertos.update((a) => new Set(a).add(grupo.titulo));
    });
  }

  @HostListener('window:scroll')
  protected alDesplazar() {
    this.abajo.set(window.scrollY > 500);
  }

  protected subir() {
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  protected abierto(titulo: string) {
    return this.abiertos().has(titulo);
  }

  protected alternarGrupo(titulo: string) {
    this.abiertos.update((a) => {
      const n = new Set(a);
      if (n.has(titulo)) n.delete(titulo); else n.add(titulo);
      return n;
    });
  }

  /** No se aceptan emojis en ningún campo del sistema: se quitan mientras se escribe. */
  @HostListener('document:input', ['$event'])
  protected sinEmojis(e: Event) {
    const el = e.target as HTMLInputElement | HTMLTextAreaElement | null;
    if (!el || !('value' in el) || (el as HTMLInputElement).type === 'file') return;
    const limpio = el.value.replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}]/gu, '');
    if (limpio !== el.value) {
      el.value = limpio;
      el.dispatchEvent(new Event('input'));
    }
  }

  protected cambiar(r: Rol) {
    this.eligiendo.set(false);
    this.auth.cambiarRol(r);
  }
  protected readonly menu = computed(() => {
    const rol = this.auth.rolActivo();
    return MENU.map((g) => ({ titulo: g.titulo, enlaces: g.enlaces.filter((e) => rol && e.roles.includes(rol)) }))
      .filter((g) => g.enlaces.length);
  });
}
