import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { claseEstado, fechaHora, hoyIso, textoEstado } from '../core/formato';
import { Pagina, paginaVacia, Paginador, POR_PAGINA } from '../core/paginador';

interface Evento { auditoria_id: number; created_at: string; email: string | null; rol_actuante: string | null; accion: string;
  entidad: string; entidad_id: string | null; instancia_api: string | null; ip_origen: string | null }
interface Correo { notificacion_id: number; tipo: string; destinatario: string; asunto: string; estado: string; intentos: number;
  ultimo_error: string | null; proveedor_msg_id: string | null; created_at: string; enviada_at: string | null }

/** Fecha de hace `dias` días (AAAA-MM-DD, hora de Ecuador). */
function haceDias(dias: number): string {
  const d = new Date(Date.now() - dias * 86_400_000);
  return d.toLocaleDateString('en-CA', { timeZone: 'America/Guayaquil' });
}

@Component({
  selector: 'app-auditoria',
  imports: [FormsModule, Paginador],
  template: `
    <h1>Auditoría y correos</h1>
    <p class="sub">Trazabilidad de operaciones (también replicada en MongoDB Atlas) y bandeja de salida de Mailjet.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <div class="card tabla-scroll">
      <h2>Eventos</h2>
      <form class="fila" (ngSubmit)="cargarEventos(1)">
        <div class="campo"><label for="ed">Desde</label><input id="ed" type="date" name="ed" [(ngModel)]="f.desde" /></div>
        <div class="campo"><label for="eh">Hasta</label><input id="eh" type="date" name="eh" [(ngModel)]="f.hasta" /></div>
        <div class="campo"><label for="ea">Acción</label>
          <select id="ea" name="ea" [(ngModel)]="f.accion"><option value="">Todas</option>
            @for (a of acciones(); track a) { <option [value]="a">{{ a }}</option> }</select></div>
        <div class="campo"><label for="eu">Usuario</label>
          <input id="eu" name="eu" maxlength="100" [(ngModel)]="f.usuario" placeholder="parte del correo o «sistema»" /></div>
        <div class="campo botones">
          <button type="submit">Filtrar</button>
          <button type="button" class="secundario" (click)="limpiar()">Limpiar</button>
        </div>
      </form>
      <table>
        <thead><tr><th>Fecha</th><th>Usuario</th><th>Rol</th><th>Acción</th><th>Entidad</th><th>API</th><th>IP</th></tr></thead>
        <tbody>
          @for (e of eventos().items; track e.auditoria_id) {
            <tr><td>{{ fechaHora(e.created_at) }}</td><td>{{ e.email ?? 'sistema' }}</td><td>{{ e.rol_actuante }}</td>
              <td><strong>{{ e.accion }}</strong></td><td>{{ e.entidad }} {{ e.entidad_id }}</td><td>{{ e.instancia_api }}</td><td>{{ e.ip_origen }}</td></tr>
          } @empty { <tr><td colspan="7" class="vacio">{{ cargando() ? 'Cargando…' : 'No hay eventos con esos filtros.' }}</td></tr> }
        </tbody>
      </table>
      <app-paginador [pagina]="eventos()" (cambiar)="cargarEventos($event)" />
    </div>

    <div class="card tabla-scroll">
      <div class="entre">
        <h2>Correos (Mailjet)</h2>
        <form class="fila" (ngSubmit)="prueba()">
          <input type="email" name="c" maxlength="150" [(ngModel)]="correoPrueba" placeholder="correo para prueba" />
          <button type="submit" class="secundario chico" [disabled]="!correoPrueba">Enviar prueba</button>
          <button type="button" class="chico" (click)="procesar()">Enviar pendientes</button>
        </form>
      </div>
      <form class="fila" (ngSubmit)="cargarCorreos(1)">
        <div class="campo"><label for="ce">Estado</label>
          <select id="ce" name="ce" [(ngModel)]="fc.estado"><option value="">Todos</option>
            @for (e of estadosCorreo; track e) { <option [value]="e">{{ textoEstado(e) }}</option> }</select></div>
        <div class="campo"><label for="cq">Destinatario o asunto</label><input id="cq" name="cq" maxlength="100" [(ngModel)]="fc.q" /></div>
        <div class="campo botones"><button type="submit">Filtrar</button></div>
      </form>
      <table>
        <thead><tr><th>Fecha</th><th>Tipo</th><th>Destinatario</th><th>Asunto</th><th>Estado</th><th>ID Mailjet</th></tr></thead>
        <tbody>
          @for (c of correos().items; track c.notificacion_id) {
            <tr><td>{{ fechaHora(c.created_at) }}</td><td>{{ c.tipo }}</td><td>{{ c.destinatario }}</td><td>{{ c.asunto }}</td>
              <td><span [class]="claseEstado(c.estado)">{{ textoEstado(c.estado) }}</span>
                @if (c.ultimo_error) { <br /><small class="fuera">{{ c.ultimo_error }}</small> }</td>
              <td><small>{{ c.proveedor_msg_id }}</small></td></tr>
          } @empty { <tr><td colspan="6" class="vacio">Sin correos.</td></tr> }
        </tbody>
      </table>
      <app-paginador [pagina]="correos()" (cambiar)="cargarCorreos($event)" />
    </div>
  `,
  styles: `.botones { flex-direction: row; gap: 8px; flex: 0 0 auto; }`,
})
export class Auditoria implements OnInit {
  private readonly api = inject(Api);
  protected readonly fechaHora = fechaHora;
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly estadosCorreo = ['PENDIENTE', 'ENVIADA', 'FALLIDA'];
  protected readonly eventos = signal<Pagina<Evento>>(paginaVacia());
  protected readonly correos = signal<Pagina<Correo>>(paginaVacia());
  protected readonly acciones = signal<string[]>([]);
  protected readonly cargando = signal(false);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  // Por defecto, los últimos 7 días: la tabla de auditoría crece sin límite.
  protected f = { desde: haceDias(7), hasta: hoyIso(), accion: '', usuario: '' };
  protected fc = { estado: '', q: '' };
  protected correoPrueba = '';

  ngOnInit() {
    this.cargarEventos(1);
    this.cargarCorreos(1);
    this.api.get<string[]>('/api/auditoria/acciones').then((a) => this.acciones.set(a)).catch(() => undefined);
  }

  limpiar() {
    this.f = { desde: '', hasta: '', accion: '', usuario: '' };
    this.cargarEventos(1);
  }

  async cargarEventos(pagina: number) {
    this.cargando.set(true);
    this.error.set('');
    try {
      this.eventos.set(await this.api.get<Pagina<Evento>>('/api/auditoria', { ...this.f, pagina, por_pagina: POR_PAGINA }));
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.cargando.set(false);
    }
  }

  async cargarCorreos(pagina: number) {
    try {
      this.correos.set(await this.api.get<Pagina<Correo>>('/api/notificaciones', { ...this.fc, pagina, por_pagina: 10 }));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async prueba() {
    try {
      const r = await this.api.post<{ mailjet_message_id: string }>('/api/notificaciones/prueba', { email: this.correoPrueba });
      this.aviso.set(`Correo enviado (Mailjet ${r.mailjet_message_id}).`);
      await this.cargarCorreos(1);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async procesar() {
    try {
      const r = await this.api.post<{ enviadas: number; fallidas: number }>('/api/notificaciones/procesar');
      this.aviso.set(`${r.enviadas} enviados, ${r.fallidas} con error.`);
      await this.cargarCorreos(1);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
