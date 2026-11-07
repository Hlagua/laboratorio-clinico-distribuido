import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { claseEstado, dinero, fechaHora, textoEstado } from '../core/formato';
import { Pago } from '../core/modelos';

@Component({
  selector: 'app-pagos',
  imports: [FormsModule],
  template: `
    <h1>Pagos y reembolsos</h1>
    <p class="sub">Pagos con Stripe (modo prueba) y transferencias con QR. Los pagos de Stripe se confirman solos por webhook.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    <div class="card fila">
      <div class="campo"><label for="e">Estado</label>
        <select id="e" [(ngModel)]="estado" (change)="cargar()">
          <option value="">Todos</option>
          @for (e of estados; track e) { <option [value]="e">{{ textoEstado(e) }}</option> }
        </select></div>
    </div>
    <div class="card tabla-scroll">
      <table>
        <thead><tr><th>#</th><th>Solicitud</th><th>Paciente</th><th>Método</th><th class="num">Monto</th><th class="num">Reembolsado</th><th>Estado</th><th>Fecha</th><th></th></tr></thead>
        <tbody>
          @for (p of pagos(); track p.pago_id) {
            <tr>
              <td>{{ p.pago_id }}</td><td>{{ p.solicitud_codigo }}</td><td>{{ p.paciente }}</td>
              <td>{{ p.metodo === 'STRIPE' ? 'Stripe' : 'Transferencia ' + (p.referencia_transferencia ?? '') }}</td>
              <td class="num">{{ dinero(p.monto) }}</td><td class="num">{{ p.monto_reembolsado > 0 ? dinero(p.monto_reembolsado) : '' }}</td>
              <td><span [class]="claseEstado(p.estado)">{{ textoEstado(p.estado) }}</span>
                @if (p.motivo_rechazo) { <br /><small class="muted">{{ p.motivo_rechazo }}</small> }</td>
              <td>{{ fechaHora(p.confirmado_at ?? p.created_at) }}</td>
              <td class="acciones">
                @if (p.metodo === 'TRANSFERENCIA_QR' && p.estado === 'PENDIENTE') {
                  <button class="chico" (click)="confirmar(p, true)">Confirmar</button>
                  <button class="secundario chico" (click)="confirmar(p, false)">Rechazar</button>
                }
                @if (p.estado === 'APROBADO' || p.estado === 'REEMBOLSO_PARCIAL') {
                  <button class="secundario chico" (click)="abrirReembolso(p)">Reembolsar</button>
                }
              </td>
            </tr>
          } @empty { <tr><td colspan="9" class="vacio">Sin pagos.</td></tr> }
        </tbody>
      </table>
    </div>

    @if (seleccionado(); as p) {
      <form class="card" (ngSubmit)="reembolsar()">
        <h2>Reembolso del pago #{{ p.pago_id }} ({{ p.solicitud_codigo }})</h2>
        <p class="muted">Pagado {{ dinero(p.monto) }} · ya reembolsado {{ dinero(p.monto_reembolsado) }} ·
          disponible {{ dinero(p.monto - p.monto_reembolsado) }}
          @if (p.metodo === 'STRIPE') { · se devolverá a la tarjeta por Stripe }</p>
        <div class="fila">
          <div class="campo"><label>Monto (USD)</label><input type="number" step="0.01" min="0.01" name="m" [(ngModel)]="monto" required /></div>
          <div class="campo" style="flex: 3"><label>Motivo</label><input name="mo" [(ngModel)]="motivo" required /></div>
        </div>
        <div class="fila">
          <button type="submit" class="peligro" [disabled]="!monto || !motivo">Emitir reembolso</button>
          <button type="button" class="secundario" (click)="seleccionado.set(null)">Cancelar</button>
        </div>
      </form>
    }
  `,
  styles: `.acciones { white-space: nowrap; } .acciones button { margin: 2px; }`,
})
export class Pagos implements OnInit {
  private readonly api = inject(Api);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly dinero = dinero;
  protected readonly fechaHora = fechaHora;
  protected readonly estados = ['PENDIENTE', 'APROBADO', 'RECHAZADO', 'EXPIRADO', 'REEMBOLSO_PARCIAL', 'REEMBOLSADO'];
  protected estado = '';
  protected monto: number | null = null;
  protected motivo = '';
  protected readonly pagos = signal<Pago[]>([]);
  protected readonly seleccionado = signal<Pago | null>(null);
  protected readonly error = signal('');
  protected readonly aviso = signal('');

  ngOnInit() {
    this.cargar();
  }

  async cargar() {
    try {
      this.pagos.set(await this.api.get<Pago[]>('/api/pagos', { estado: this.estado }));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async confirmar(p: Pago, aprobado: boolean) {
    const motivo = aprobado ? null : prompt('Motivo del rechazo:');
    if (!aprobado && !motivo) return;
    await this.ejecutar(() => this.api.post(`/api/pagos/${p.pago_id}/confirmar-transferencia`, { aprobado, motivo }),
      aprobado ? 'Transferencia confirmada.' : 'Transferencia rechazada.');
  }

  abrirReembolso(p: Pago) {
    this.seleccionado.set(p);
    this.monto = Number((p.monto - p.monto_reembolsado).toFixed(2));
    this.motivo = '';
  }

  async reembolsar() {
    const p = this.seleccionado()!;
    if (!confirm(`¿Reembolsar USD ${this.monto} del pago #${p.pago_id}? Esta acción no se puede deshacer.`)) return;
    await this.ejecutar(() => this.api.post(`/api/pagos/${p.pago_id}/reembolso`, { monto: this.monto, motivo: this.motivo }),
      'Reembolso registrado.');
    this.seleccionado.set(null);
  }

  private async ejecutar(fn: () => Promise<unknown>, exito: string) {
    this.error.set('');
    this.aviso.set('');
    try {
      await fn();
      this.aviso.set(exito);
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
