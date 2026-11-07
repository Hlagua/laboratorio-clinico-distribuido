import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { claseEstado, fechaHora, textoEstado } from '../core/formato';

interface Evento { auditoria_id: number; created_at: string; email: string | null; rol_actuante: string | null; accion: string;
  entidad: string; entidad_id: string | null; instancia_api: string | null; ip_origen: string | null }
interface Correo { notificacion_id: number; tipo: string; destinatario: string; asunto: string; estado: string; intentos: number;
  ultimo_error: string | null; proveedor_msg_id: string | null; created_at: string; enviada_at: string | null }

@Component({
  selector: 'app-auditoria',
  imports: [FormsModule],
  template: `
    <h1>Auditoría y correos</h1>
    <p class="sub">Trazabilidad de operaciones (también replicada en MongoDB Atlas) y bandeja de salida de Mailjet.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <div class="card tabla-scroll">
      <div class="entre"><h2>Últimos eventos</h2><button class="secundario chico" (click)="cargar()">Actualizar</button></div>
      <table>
        <thead><tr><th>Fecha</th><th>Usuario</th><th>Rol</th><th>Acción</th><th>Entidad</th><th>API</th><th>IP</th></tr></thead>
        <tbody>
          @for (e of eventos(); track e.auditoria_id) {
            <tr><td>{{ fechaHora(e.created_at) }}</td><td>{{ e.email ?? 'sistema' }}</td><td>{{ e.rol_actuante }}</td>
              <td><strong>{{ e.accion }}</strong></td><td>{{ e.entidad }} {{ e.entidad_id }}</td><td>{{ e.instancia_api }}</td><td>{{ e.ip_origen }}</td></tr>
          }
        </tbody>
      </table>
    </div>

    <div class="card tabla-scroll">
      <div class="entre">
        <h2>Correos (Mailjet)</h2>
        <form class="fila" (ngSubmit)="prueba()">
          <input type="email" name="c" [(ngModel)]="correoPrueba" placeholder="correo para prueba" />
          <button type="submit" class="secundario chico" [disabled]="!correoPrueba">Enviar prueba</button>
          <button type="button" class="chico" (click)="procesar()">Enviar pendientes</button>
        </form>
      </div>
      <table>
        <thead><tr><th>Fecha</th><th>Tipo</th><th>Destinatario</th><th>Asunto</th><th>Estado</th><th>ID Mailjet</th></tr></thead>
        <tbody>
          @for (c of correos(); track c.notificacion_id) {
            <tr><td>{{ fechaHora(c.created_at) }}</td><td>{{ c.tipo }}</td><td>{{ c.destinatario }}</td><td>{{ c.asunto }}</td>
              <td><span [class]="claseEstado(c.estado)">{{ textoEstado(c.estado) }}</span>
                @if (c.ultimo_error) { <br /><small class="fuera">{{ c.ultimo_error }}</small> }</td>
              <td><small>{{ c.proveedor_msg_id }}</small></td></tr>
          }
        </tbody>
      </table>
    </div>
  `,
})
export class Auditoria implements OnInit {
  private readonly api = inject(Api);
  protected readonly fechaHora = fechaHora;
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly eventos = signal<Evento[]>([]);
  protected readonly correos = signal<Correo[]>([]);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected correoPrueba = '';

  ngOnInit() {
    this.cargar();
  }

  async cargar() {
    try {
      const [e, c] = await Promise.all([
        this.api.get<Evento[]>('/api/auditoria', { limite: 50 }),
        this.api.get<Correo[]>('/api/notificaciones'),
      ]);
      this.eventos.set(e);
      this.correos.set(c.slice(0, 50));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async prueba() {
    try {
      const r = await this.api.post<{ mailjet_message_id: string }>('/api/notificaciones/prueba', { email: this.correoPrueba });
      this.aviso.set(`Correo enviado (Mailjet ${r.mailjet_message_id}).`);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async procesar() {
    try {
      const r = await this.api.post<{ enviadas: number; fallidas: number }>('/api/notificaciones/procesar');
      this.aviso.set(`${r.enviadas} enviados, ${r.fallidas} con error.`);
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
