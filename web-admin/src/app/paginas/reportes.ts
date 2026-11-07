import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { dinero, hoyIso } from '../core/formato';

interface FilaIngreso { dia: string; metodo: string; pagos: number; bruto: number; reembolsado: number; neto: number }
interface FilaExamen { codigo: string; nombre: string; solicitados: number; con_resultado: number }

@Component({
  selector: 'app-reportes',
  imports: [FormsModule],
  template: `
    <h1>Reportes</h1>
    <p class="sub">Información para la gestión del laboratorio.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }

    @if (auth.tiene('ADMIN')) {
      <div class="card">
        <div class="entre">
          <h2>Ingresos</h2>
          <div class="fila">
            <div class="campo"><label>Desde</label><input type="date" [(ngModel)]="desde" /></div>
            <div class="campo"><label>Hasta</label><input type="date" [(ngModel)]="hasta" /></div>
            <div class="campo"><button class="secundario" (click)="ingresos()">Consultar</button></div>
            <div class="campo"><button (click)="pdf()">PDF</button></div>
          </div>
        </div>
        <div class="tabla-scroll">
          <table>
            <thead><tr><th>Día</th><th>Método</th><th class="num">Pagos</th><th class="num">Bruto</th><th class="num">Reembolsado</th><th class="num">Neto</th></tr></thead>
            <tbody>
              @for (f of filas(); track f.dia + f.metodo) {
                <tr><td>{{ f.dia }}</td><td>{{ f.metodo }}</td><td class="num">{{ f.pagos }}</td><td class="num">{{ dinero(f.bruto) }}</td>
                  <td class="num">{{ dinero(f.reembolsado) }}</td><td class="num"><strong>{{ dinero(f.neto) }}</strong></td></tr>
              } @empty { <tr><td colspan="6" class="vacio">Sin pagos en el período.</td></tr> }
            </tbody>
            <tfoot><tr><td colspan="5"><strong>Total neto</strong></td><td class="num"><strong>{{ dinero(total()) }}</strong></td></tr></tfoot>
          </table>
        </div>
      </div>
    }

    <div class="card">
      <h2>Exámenes más solicitados</h2>
      @for (e of examenes(); track e.codigo) {
        <div class="barra">
          <span class="etq">{{ e.nombre }}</span>
          <span class="pista"><span class="relleno" [style.width.%]="maximo() ? (e.solicitados / maximo()) * 100 : 0"></span></span>
          <span class="num">{{ e.solicitados }} <small class="muted">({{ e.con_resultado }} con resultado)</small></span>
        </div>
      }
    </div>
  `,
  styles: `
    .barra { display: grid; grid-template-columns: 200px 1fr 170px; gap: 10px; align-items: center; margin-bottom: 8px; }
    .pista { background: var(--verde-suave); border-radius: 4px; height: 14px; overflow: hidden; }
    .relleno { display: block; height: 100%; background: var(--verde); }
    @media (max-width: 600px) { .barra { grid-template-columns: 1fr; gap: 2px; } }
  `,
})
export class Reportes implements OnInit {
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly dinero = dinero;
  protected desde = new Date(Date.now() - 30 * 86_400_000).toISOString().slice(0, 10);
  protected hasta = hoyIso();
  protected readonly filas = signal<FilaIngreso[]>([]);
  protected readonly total = signal(0);
  protected readonly examenes = signal<FilaExamen[]>([]);
  protected readonly maximo = signal(0);
  protected readonly error = signal('');

  async ngOnInit() {
    try {
      const ex = await this.api.get<FilaExamen[]>('/api/reportes/examenes');
      this.examenes.set(ex);
      this.maximo.set(Math.max(0, ...ex.map((e) => e.solicitados)));
      if (this.auth.tiene('ADMIN')) await this.ingresos();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async ingresos() {
    try {
      const r = await this.api.get<{ filas: FilaIngreso[]; total_neto: number }>('/api/reportes/ingresos', { desde: this.desde, hasta: this.hasta });
      this.filas.set(r.filas);
      this.total.set(r.total_neto);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async pdf() {
    try {
      await this.api.abrirArchivo(`/api/reportes/ingresos?formato=pdf&desde=${this.desde}&hasta=${this.hasta}`);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
