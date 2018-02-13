#!/usr/bin/perl

use strict;
use utf8::all;
use SNMP;
use threads;
use threads::shared;
use List::MoreUtils qw(firstidx);
use Term::ANSIColor;
use Statistics::Basic qw(:all);

my $comm = 'public';
my $dest = 'localhost';
my $mib;
my $sess;
my $var;
my $vb;
my %snmpparms;
my %partitionI; #Guarda nos indexs das partições montadas os valores dos ids 
my @linha:shared; #Lista usada para ter a linha da thread partilhada com as threads, para atualizar dinamicamente
my %threads; #Guarda a linha em que as threads ativas devem escrever 
my %threadsTemp; #Array auxiliar para verificar se houve alterações de partições
my $total:shared = 0; #Número de threads em execução
my $input:shared = "Ola"; 
my @joinThreads;
my $threadIter = 0;
my $lock:shared;


&SNMP::initMib();

$snmpparms{Community} = $comm;
$snmpparms{DestHost} = $dest;
$snmpparms{UseSprintValue} = '1';
$sess = new SNMP::Session(%snmpparms);


#Caso de paragem do programa (Ctrl + D)
$joinThreads[$threadIter++] = async{	while($input){
											$input = <STDIN>;
										} 
										print("I am out\n");
										exit(0);
									}

particoes();
print "Label", "\t\tFree Space\tSize\n";
print "\n" x $total;
my $totalAux = $total;

while($input){
	#Para Colocar na posição certa para o print
	if($total != $totalAux){
		print "\n" x ($total-$totalAux); 
		$totalAux = $total;
	} 
	foreach my $index (keys %threads){
		#Se não existe uma thread para o FSIndex, cria uma
		if( !exists($linha[$threads{$index}]) ){
			$linha[$threads{$index}] = $index;
			$joinThreads[$threadIter++] = async{ snmpUpdate($index, $partitionI{$threads{$index}}) };
		}
		else{
			$linha[$threads{$index}] = $index;
		}
	}
	sleep(20);
	particoes();
}

foreach my $thread (@joinThreads){
	$thread->detach();
}

sub particoes{
	#Procurar quais as partições montadas
	$mib = 'hrPartitionFSIndex';
	$total = 0;
	$vb = new SNMP::Varbind([$mib]);
	for ( $var = $sess->getnext($vb);
	      ($vb->tag eq $mib) and not ($sess->{ErrorNum});
	      $var = $sess->getnext($vb)
	    ) {
		#Procurar o indice delas
		if($var > -1 ){
			$total++;
			$threadsTemp{$total} = $var;
	  		$partitionI{$var} = $vb -> iid;
	  	}
	}
	%threads = verifica(\%threads, \%threadsTemp);
}

#dados dois arrays, verifica se existe alterações do primeiro ao segundo, 
#e se sim, acrescenta as novas alterações ao primeiro, adicionando os novos valores
#e removendo os valores das partições que foram desmontadas
sub verifica{
	my ($array, $arrayTemp) = @_;		
	my $iter = 1;
	my $exists = 0;
	my $index;
	while($iter != $total+1){
		$exists = 0;
		foreach my $aux (keys %$array){
			if($arrayTemp->{$iter} eq $array->{$aux}){
				$index = $aux;
				$exists = 1;
				last;
			}
		}
		if($exists == 1 & $index != $iter){
			$arrayTemp->{$iter} = $arrayTemp->{$index};
			$arrayTemp->{$index} = $array->{$index};
		}
		$iter++;
	}
	return %$arrayTemp;
}

sub snmpUpdate{
	my ($index, $iid) = @_;
	my $freeAnt = "0";
	my $counter = 0;
	#Array utilizado para auxílio do calculo do intervalo de monitorização
	my @arrayFree;
	$|=1;

	while(1){

		$mib = "hrPartitionFSIndex";
		$index = snmpGet($mib, $iid);
		if(!$input){
			die;
		}

		$mib = "hrPartitionLabel"; 												#Procurar o label
		my $label = snmpGet($mib, $iid);
		$label = substr($label, 1, length($label)-2);

		$mib = "hrFSStorageIndex";												#Procurar o index do Storage
		my $indice = snmpGet($mib, $index);
				
		if(defined $indice){
			$mib = "hrStorageSize";													#Procurar a memória total da partição
			my $size = snmpGet($mib, $indice);
					
			$mib = "hrStorageUsed";													#Procurar a memória usada da partição
			my $used = snmpGet($mib, $indice);

			$mib = "hrStorageAllocationUnits";										#Procurar as unidades dos valores da hrStorage
			my $units = snmpGet($mib, $indice);
			my $sizeC = $size * $units / (1024**3);									#Calcular o tamanho da partição em unidades corretas
			my $free = 100-($used/$size*100); 										#Calcular a percentagem de memória livre da partição
				
			$free = substr( $free, 0, 5 );

			if($counter < 9){ 
				$arrayFree[$counter++] = $free;
			}
			else{ 
				shift(@arrayFree);
				$arrayFree[$counter] = $free;
			}

			
			$sizeC = substr( $sizeC, 0, 5 );
			if($free ne $freeAnt){
				{
					lock($lock);
					print "\e[A" x ($total-$linha[$index]+1), "\r";
					print "\n" x ($total-$linha[$index]-1);
					printf "$label\t";
					printf("%s\t\t", colored(['bright_black on_white'], $free."%"));
					printf "%sGB\n", $sizeC;
					print "\n" x ($total-$linha[$index]);
				}
				sleep(1);
			}

			my $media = mean(@arrayFree);
			my $sttevTot = stddev(@arrayFree);
			my @arrayAux = @arrayFree;
			my @arrayFreePar = splice @arrayAux, 5, 5;
			my $sttevPar = stddev (@arrayFreePar);
			my $result = 30-(2.5*(300/($media+15)))-($sttevTot/4)-$sttevPar;
			if($result < 2 || $counter < 9){ $result = 2; }


			$freeAnt = $free;
			{
				lock($lock);
				print "\e[A" x ($total-$linha[$index]+1), "\r";
				print "\n" x ($total-$linha[$index]-1);
				printf "$label\t";
				if($free < 10){ printf("%s\t\t", colored($free."%", "red")); }
				if($free < 50 & $free >= 10){ printf("%s\t\t", colored($free."%", "bright_yellow")); }
				if($free >= 50){ printf("%s\t\t", colored($free."%", "bright_green")); }
				printf "%sGB\n", $sizeC;
				print "\n" x ($total-$linha[$index]);
			}
			sleep($result);
		}
		else{
			{
				lock($lock);
				print "\e[A" x ($total-$linha[$index]+1), "\r";
				print "\n" x ($total-$linha[$index]-1);
				printf "$label\t-----%\t\t-----GB\n";
				print "\n" x ($total-$linha[$index]);
			}
			sleep(10000);
		}
	}
}

sub snmpGet{
	my ($mib, $index) = @_;
	$vb = new SNMP::Varbind([$mib, $index]);
	$var = $sess->get($vb);
	if ($sess->{ErrorNum}) {
		$var = undef;
	}
	return $var;
}