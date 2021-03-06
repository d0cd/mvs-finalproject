/* tipo di richiesta */
#define REQUEST 0
#define RELEASE 1

#define BUSY 0
#define AVAILABLE 1


/* definizioni per formule LTL */
#define ces1_start 	(ces[ces_pid1]@start)
#define ces2_start 	(ces[ces_pid2]@start)

#define max_one_g1 (!(ces[ces_pid1]:pid_garage == g_pid1 && ces[ces_pid2]:pid_garage == g_pid1))
#define max_one_g2 (!(ces[ces_pid1]:pid_garage == g_pid2 && ces[ces_pid2]:pid_garage == g_pid2))
#define max_one_tt (!(ces[ces_pid1]:pid_towtruck == tt_pid && ces[ces_pid2]:pid_towtruck == tt_pid))
#define max_one_rc (!(ces[ces_pid1]:pid_rentalcar == rc_pid && ces[ces_pid2]:pid_rentalcar == rc_pid))

#define ces1_damage (ces[ces_pid1]@damage)
#define ces2_damage (ces[ces_pid2]@damage)

#define ces1_no_book_g	(ces[ces_pid1]:pid_garage == 0)
#define ces2_no_book_g	(ces[ces_pid2]:pid_garage == 0)


/* macro per testare se un servizio è non prenotato */
#define notBooked(v, n)	(!(v >> (n) & 1))
/* macro per prenotare e rilasciare un servizio */
#define Book(v, n)		v = v | (1 << (n))
#define Cancel(v, n)	v = v & ~(1 << (n))


/* numero di garage */
#define NGARAGE 2


/* canale carta di credito */
chan creditcard_ch = [0] of {bit};

/* canali officine */
chan garage_chs [NGARAGE] = [0] of {bit, byte};

/* canale carro attrezzi */
chan towtruck_ch = [0] of {bit, byte};

/* canale noleggio auto */
chan rentalcar_ch = [0] of {bit, byte};


/* variabili globali accedute localmente all'interno dell'init
   indicano il pid dei servizi */
local byte ces_pid1 = 0;
local byte ces_pid2 = 0;
local byte g_pid1 = 0;
local byte g_pid2 = 0;
local byte tt_pid = 0;
local byte rc_pid = 0;


/* variabili che indicano se un ces ha prenotato un servizio;
   per le officine utilizziamo una variabile di tipo byte e
   il test è effettuato con la macro sopra definita
   NOTA: la scelta di avere una variabile di tipo byte limita
   		 il numero di servizi di una tipologia al più 8 */
byte garage_booked = 0;

bool towtruck_booked = false;

bool rentalcar_booked = false;


/* car emergency system */
proctype ces()
{
		/* ha un abbonamento? */
		bool subscribing;
		bool result;
		/* pid dei servizi prenotati:
		   se pid == 0 allora il servizio non è prenotato
		   altrimenti il pid è usato come ricevuta di prenotazione */
		byte pid_garage = 0, pid_towtruck = 0, pid_rentalcar = 0;
		/* indice del canale dei servizi prenotati (per servizi con più istanze) */
		byte idg = 0;

		/* scelta non-deterministica se è abbonato o meno */
start:	if
		:: subscribing = false
		:: subscribing = true
		fi;

damage:	if
		/* è abbonato */
		:: subscribing ->
sub:	skip
		/* non è abbonato, richiedo l'autorizzazione per la
	   	   prenotazione con carta di credito */
		:: !subscribing ->
			creditcard_ch ! REQUEST;
			creditcard_ch ? result;
			if
			/* autorizzazione ottenuta */
			:: result -> 
auth:			skip
			/* autorizzazione negata */
			:: !result -> goto fail
			fi
		fi;

		/* tentativo di prenotazione dell'officina */
reqG:	for(idg in garage_chs) {
			if
			/* se la idg-esima officina non è prenotata da un altro ces
			   ottengo il canala di comunicazione in mutua esclusione */
			:: atomic { notBooked(garage_booked, idg) ->
				Book(garage_booked, idg) };
				garage_chs[idg] ! REQUEST, 0;
				garage_chs[idg] ? result, pid_garage;
				if
				/* officina prenotata */
				:: result -> goto reqTT
				/* officina occupata, la rilascio e continuo ad iterare */
				:: !result -> Cancel(garage_booked, idg)
				fi
			/* altrimenti continuo ad iterare */
			:: else -> skip
			fi
		}
		/* se viene raggiunto questo punto allora tutte le prenotazioni sono fallite */
		goto fail;
		
		/* tentativo di prenotazione del carro attrezzi */
reqTT:	if
		:: atomic { !towtruck_booked ->
			towtruck_booked = true };
			towtruck_ch ! REQUEST, 0;
			towtruck_ch ? result, pid_towtruck;
			if
			/* carro attrezzi prenotato */
			:: result -> skip
			/* carro attrezzi occupato, prenotazione fallita */
			:: !result -> towtruck_booked = false;
				goto fail
			fi
		/* se il servizio è già prenotato, la richiesta è fallita */
		:: else -> goto fail
		fi;

		/* tentativo di prenotazione del noleggio auto */
reqRC:	if
		:: atomic { !rentalcar_booked ->
			rentalcar_booked = true };
			rentalcar_ch ! REQUEST, 0;
			rentalcar_ch ? result, pid_rentalcar;
			if
			:: result -> skip
			:: !result -> rentalcar_booked = false
			fi
			/* sia in caso di fallimento della prenotazione, sia in caso di successo
		   	   procedo con la riparazione
		       nota: se result == true allora pid_rentalcar != 0, ovvero vale
		   	   assert(!result || (pid_rentalcar != 0)); */
	   	/* se il servizio è già prenotato, continuo con il workflow */
	   	:: else -> skip
	    fi;

	    /* workflow è terminato con successo */
succ:	goto rel;

fail:	skip;
		/* release dei servizi prenotati */
rel:	if
		:: pid_garage != 0 ->
			garage_chs[idg] ! RELEASE, pid_garage;
			garage_chs[idg] ? AVAILABLE, pid_garage;
			Cancel(garage_booked, idg);
			if
			:: pid_towtruck != 0 ->
				towtruck_ch ! RELEASE, pid_towtruck;
				towtruck_ch ? AVAILABLE, pid_towtruck;
				towtruck_booked = false
			:: else -> skip
			fi;
			if
			:: pid_rentalcar != 0 ->
				rentalcar_ch ! RELEASE, pid_rentalcar;
				rentalcar_ch ? AVAILABLE, pid_rentalcar;
				rentalcar_booked = false
			:: else -> skip
			fi
		:: else -> skip
		fi;
		goto damage
} 


/* servizio carta di credito
   sempre disponibile e che ha sempre successo */
proctype creditcard(chan ch)
{
waitCC:	atomic { ch ? REQUEST;
		/* le richieste hanno sempre successo */
		ch ! AVAILABLE };
		goto waitCC
}


/* generico servizio inizialmente disponibile */
proctype service(chan ch)
{		
waitS:	ch ? REQUEST, _;
		ch ! AVAILABLE, _pid;
		/* il messaggio di release deve avere il pid del servizio */
bookS:	ch ? RELEASE, eval(_pid);
		ch ! AVAILABLE, 0;
		goto waitS
}


/* servizio noleggio auto
   sceglie nondeterministicamente se è disponibile od occupato */
proctype rentalcar(chan ch)
{
		/* indica se il servizio è disponibile o meno */
		bool state;
		
		/* scelta non-deterministica dello stato */
		if
		:: state = false
		:: state = true
		fi;
		
waitRC:	ch ? REQUEST, _;
		if
		/* se è disponibile allora viene prenotato */
		:: state ->
			ch ! AVAILABLE, _pid;
			/* il messaggio di release deve avere il pid del servizio */
bookRC:		ch ? RELEASE, eval(_pid);
			ch ! AVAILABLE, 0
		/* altrimenti è occupato */
		:: !state -> ch ! BUSY, 0
		fi;
		goto waitRC
}


/* inizializzazione */
init {
	atomic {
		ces_pid1 = run ces();
		ces_pid2 = run ces();
		run creditcard(creditcard_ch);
		g_pid1 = run service(garage_chs[0]);
		g_pid2 = run service(garage_chs[1]);
		tt_pid = run service(towtruck_ch);
		rc_pid = run rentalcar(rentalcar_ch)
	}
}


/* proprietà LTL */
ltl prop_d0 { [](max_one_g1 && max_one_g2 && max_one_tt && max_one_rc) }
/* Absence, after Q */
ltl prop_d { []((ces1_start && ces2_start) -> [](max_one_g1 && max_one_g2 && max_one_tt && max_one_rc)) }
ltl prop_e { []<>ces1_damage && []<>ces2_damage }
ltl prop_g { !<>[]np_ }

/* assumendo weak fainessa a livello di processi la proprietà è verificata */
ltl non_book { !((<>[]ces1_no_book_g) || (<>[]ces2_no_book_g)) }
/* quindi, se entrambi i processi si muovono, riescono sempre a prenotare un'officina */
