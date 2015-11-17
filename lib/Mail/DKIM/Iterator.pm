package Mail::DKIM::Iterator;
use v5.10.0;

our $VERSION = '0.010';

use strict;
use warnings;
use Crypt::OpenSSL::RSA;
use Scalar::Util 'dualvar';

use Exporter 'import';
our @EXPORT =qw(
    DKIM_INVALID_HDR
    DKIM_TEMPFAIL
    DKIM_SOFTFAIL
    DKIM_PERMFAIL
    DKIM_SUCCESS
);

use constant {
    DKIM_INVALID_HDR => dualvar(-3,'invalid-header'),
    DKIM_SOFTFAIL    => dualvar(-2,'soft-fail'),
    DKIM_TEMPFAIL    => dualvar(-1,'temp-fail'),
    DKIM_PERMFAIL    => dualvar( 0,'perm-fail'),
    DKIM_SUCCESS     => dualvar( 1,'valid'),
};


sub new {
    my ($class,%args) = @_;
    my $self = bless {
	records => $args{dns} || {},
	extract_sig => 1,
	_hdrbuf => '',
    }, $class;
    if (my $sig = delete $args{sign}) {
	$sig = [$sig] if ref($sig) ne 'ARRAY';
	$self->{extract_sig} = delete $args{sign_and_verify};
	my $error;
	for(@$sig) {
	    my $s = parse_signature($_,\$error,1);
	    die "bad signature '$_': $error" if !$s;
	    push @{$self->{sig}}, $s
	}
    }
    return $self;
}

# append data from mail
# returns nothing if it needs more input data
# returns partial or full response if it got enough input data
sub append {
    my ($self,$buf) = @_;
    if (defined $self->{_hdrbuf}) {
	$self->{_hdrbuf} .= $buf;
	$self->{_hdrbuf} =~m{(\r?\n)\1}g or return; # no end of header
	_parse_header($self,
	    $self->{header} = substr($self->{_hdrbuf},0,$+[0],''));
	$buf = delete $self->{_hdrbuf};
	_append_body($self,$buf) if $buf ne '';
    } else {
	_append_body($self,$buf);
    }
    return [] if !$self->{sig}; # nothing to verify or sign
    return $self->result if $self->{_bhdone};
}

# compute result based on current data
# might add more DKIM records to validate signatures
sub result {
    my ($self,$more_records) = @_;
    my $records = $self->{records};
    %$records = (%$records,%$more_records) if $more_records;
    return if defined $self->{_hdrbuf}; # need more header
    return [] if !$self->{sig};         # nothing to verify
    return if ! $self->{_bhdone};       # need more body

    my @rv;
    for my $sig (@{$self->{sig}}) {
	if (!$sig->{b}) {
	    # not for verification but for signing
	    if ($sig->{':result'}) {
		# have already result
		push @rv, $sig->{':result'}
	    } elsif (!$sig->{'bh:computed'}) {
		# incomplete
		push @rv, Mail::DKIM::Iterator::SignRecord->new($sig);
	    } else {
		# compute
		my $err;
		my $dkim_sig = sign($sig,$sig->{':key'},$self->{header},\$err);
		$sig->{':result'} = Mail::DKIM::Iterator::SignRecord->new(
		    $dkim_sig ? ($sig,$dkim_sig,DKIM_SUCCESS)
			: ($sig,undef,DKIM_PERMFAIL,$err)
		);
		push @rv,$sig->{':result'};
	    }
	    next;
	}

	if ($sig->{error}) {
	    push @rv, Mail::DKIM::Iterator::VerifyRecord->new(
		$sig,
		($sig->{s}//'UNKNOWN')."_domainkey".($sig->{d}//'UNKNOWN'),
		DKIM_INVALID_HDR,
		$sig->{error}
	    );
	    next;
	}

	my $dns = "$sig->{s}._domainkey.$sig->{d}";

	if ($sig->{x} && $sig->{x} < time()) {
	    push @rv, Mail::DKIM::Iterator::VerifyRecord
		->new($sig,$dns, DKIM_SOFTFAIL, "signature e[x]pired");
	    next;
	}

	if (my $txt = $records->{$dns}) {
	    if (!ref($txt) || ref($txt) eq 'ARRAY') {
		my $error = "no TXT records";
		for(ref($txt) ? @$txt:$txt) {
		    if (my $r = parse_dkimkey($_,\$error)) {
			$records->{$dns} = $txt = $r;
			$error = undef;
			last;
		    }
		}
		if ($error) {
		    $records->{$dns} = $txt = { permfail => $error };
		}
	    }
	    # use DKIM record for validation
	    push @rv, Mail::DKIM::Iterator::VerifyRecord
		->new($sig,$dns, _verify_sig($self,$sig,$txt));
	} elsif (exists $records->{$dns}) {
	    # cannot get DKIM record
	    push @rv, Mail::DKIM::Iterator::VerifyRecord
		->new($sig,$dns, DKIM_TEMPFAIL, "dns lookup failed");
	} else {
	    # no DKIM record yet known for $dns
	    push @rv, Mail::DKIM::Iterator::VerifyRecord->new($sig,$dns);
	}
    }
    return \@rv;
}

sub parse_signature {
    my ($v,$error,$for_signing) = @_;
    $v = _parse_taglist($v,$error) or return if !ref($v);

    if ($for_signing) {
	# some defaults
	$v->{v} //= '1';
    }

    if (($v->{v}//'') ne '1') {
	$$error = "bad DKIM signature version: ".($v->{v}||'<undef>');
    } elsif (!$v->{d}) {
	$$error = "required [d]omain not given";
    } elsif (!$v->{s}) {
	$$error = "required [s]elector not given";
    } elsif (!$v->{h}) {
	$$error = "required [h]eader fields not given";
    } elsif ($v->{l} && $v->{l} !~m{^\d{1,76}\z}) {
	$$error = "invalid body [l]ength";
    } elsif (do {
	$v->{q} = lc($v->{q}//'dns/txt');
	$v->{q} ne 'dns/txt'
    }) {
	$$error = "unsupported query method $v->{q}";
    }
    return if $$error;

    $v->{d} = lc($v->{d});
    $v->{a} = lc($v->{a}//'rsa-sha256');
    $v->{c} = lc($v->{c}//'simple/simple');
    $v->{'h:list'} = do {
	# some signatures have the same field twice in h - sanitize
	my %h;
	[ grep { !$h{$_}++ } split(/\s*:\s*/,lc($v->{h})) ];
    };

    if ($for_signing) {
	delete $v->{b};
	delete $v->{bh};
	$v->{t} = undef if exists $v->{t};
	if (defined $v->{x} && $v->{x} !~m{^\+?\d{1,12}\z}) {
	    $$error = "invalid e[x]piration time";
	}
    } else {
	if (!$v->{b} or not $v->{'b:bin'} = _decode64($v->{b})) {
	    $$error = "invalid body signature: ".($v->{b}||'<undef>');
	} elsif (!$v->{bh} or not $v->{'bh:bin'} = _decode64($v->{bh})) {
	    $$error = "invalid header signature: ".($v->{bh}||'<undef>');
	} elsif ($v->{t} && $v->{t} !~m{^\d{1,12}\z}) {
	    $$error = "invalid [t]imestamp";
	} elsif ($v->{x}) {
	    if ($v->{x} !~m{^\d{1,12}\z}) {
		$$error = "invalid e[x]piration time";
	    } elsif ($v->{t} && $v->{x} < $v->{t}) {
		$$error = "expiration precedes timestamp";
	    }
	}

	if ($v->{i}) {
	    $v->{i} = _decodeQP($v->{i});
	    if (lc($v->{i}) =~m{\@([^@]+)$}) {
		$v->{'i:domain'} = $1;
		$$error ||= "[i]dentity does not match [d]omain"
		    if $v->{'i:domain'} !~m{^(.+\.)?\Q$v->{d}\E\z};
	    } else {
		$$error = "no domain in identity";
	    }
	} else {
	    $v->{i} = '@'.$v->{d};
	}
    }

    my ($hdrc,$bodyc) = $v->{c}
	=~m{^(relaxed|simple)(?:/(relaxed|simple))?$} or do {
	$$error ||= "invalid canonicalization $v->{c}";
    };
    $bodyc ||= 'simple';
    my ($kalgo,$halgo) = $v->{a} =~m{^(rsa)-(sha(?:1|256))$} or do {
	$$error ||= "unsupported algorithm $v->{a}";
    };
    return if $$error;

    $v->{'c:hdr'}  = $hdrc;
    $v->{'c:body'} = $bodyc;
    $v->{'a:key'}  = $kalgo;
    $v->{'a:hash'} = $halgo;

    # ignore: z
    return $v;
}

sub parse_dkimkey {
    my ($v,$error) = @_;
    $v = _parse_taglist($v,$error) or return if !ref($v);
    if (!$v || !%$v) {
	$$error = "invalid or empty DKIM record";
	return;
    }

    if (($v->{v}||='DKIM1') ne 'DKIM1') {
	$$error = "bad DKIM record version: $v->{v}";
    } elsif (($v->{k}//='rsa') ne 'rsa') {
	$$error = "unsupported key type $v->{k}";
    } else {
	if (exists $v->{g}) {
	    # g is deprecated in RFC 6376
	    if (1) {
		delete $v->{g}
	    } else {
		$v->{g} = ($v->{g}//'') =~m{^(.*)\*(.*)$}
		    ? qr{^\Q$1\E.*\Q$2\E\@[^@]+\z}
		    : qr{^\Q$v->{g}\E\@[^@]+\z};
	    }
	}
	$v->{t} = { map { $_ => 1 } split(':',lc($v->{t} || '')) };
	$v->{h} = { map { $_ => 1 } split(':',lc($v->{h} || 'sha1:sha256')) };
	$v->{s} = { map { $_ => 1 } split(':',lc($v->{s} || '*')) };
	if (!$v->{s}{'*'} && !$v->{s}{email}) {
	    $$error = "service type " . join(':',keys %{$v->{s}})
		. " does not match";
	    return;
	}
	return $v;
    }
    return;
}

sub sign {
    my ($sig,$key,$hdr,$error) = @_;
    $sig = parse_signature($sig,$error,1) or return;

    my %sig = %$sig;
    $sig{t} = time() if !$sig{t} && exists $sig{t};
    $sig{x} = ($sig{t} || time()) + $1
	if $sig{x} && $sig{x} =~m{^\+(\d+)$};
    $sig{'a:key'} eq 'rsa' or do {
	$$error = "unsupported algorithm ".$sig{'a:key'};
	return;
    };
    delete $sig{b};
    $sig{i} = _encodeQP($sig{':i'}) if $sig{':i'};
    $sig{z} = _encodeQP($sig{':z'}) if $sig{':z'};
    $sig{bh} = _encode64($sig{'bh:computed'} || $sig{'bh:bin'});
    $sig{h} = join(':',@{$sig{'h:list'}});

    my @v;
    for (qw(v a c d q s t x h l i z bh)) {
	my $v = delete $sig{$_} // next;
	push @v, "$_=$v"
    }
    for(sort keys %sig) {
	m{:} and next;
	my $v = _encodeQP(delete $sig{$_} // next);
	push @v, "$_=$v"
    }

    my @lines = shift(@v);
    for(@v,"b=") {
	$lines[-1] .= ';';
	my $append = " $_";
	my $x80 = (@lines == 1 ? 64 : 80) - length($lines[-1]);
	if (length($append)<=$x80) {
	    $lines[-1] .= $append;
	} elsif (length($append)<=80) {
	    push @lines,$append;
	} else {
	    while (1) {
		if ( $x80>10) {
		    $lines[-1] .= substr($append,0,$x80,'');
		    $append eq '' and last;
		}
		push @lines,'';
		$x80 = 80;
	    }
	}
    }

    my $dkh = 'DKIM-Signature: '.join("\r\n",@lines);
    $sig->{'a:key'} eq 'rsa' or do {
	$$error = "unsupported signature algorithm $sig->{'a:key'}";
	return;
    };
    my $hash = _compute_hdrhash($hdr,
	$sig{'h:list'},$sig->{'a:hash'},$sig->{'c:hdr'},$dkh);

    my $priv = ref($key) ? $key : Crypt::OpenSSL::RSA->new_private_key($key);
    $priv or do {
	$$error = "using private key failed";
	return;
    };
    $priv->use_no_padding;

     my $data = _encode64($priv->decrypt(
	_emsa_pkcs1_v15($sig->{'a:hash'},$hash,$priv->size)));

    my $x80 = 80 - ($dkh =~m{\n([^\n]+)\z} && length($1));
    while ($data ne '') {
	$dkh .= substr($data,0,$x80,'')."\r\n" if $x80>10;
	$dkh .= " " if $data ne '';
	$x80 = 80;
    }
    return $dkh;
}

{
    my %sig_prefix = (
	'sha1'   => pack("H*","3021300906052B0E03021A05000414"),
	'sha256' => pack("H*","3031300d060960864801650304020105000420"),
    );

    # EMSA-PKCS1-v1_5
    # RFC 3447 9.2
    sub _emsa_pkcs1_v15 {
	my ($algo,$hash,$len) = @_;
	my $t = ($sig_prefix{$algo} || die "unsupport digest $algo") . $hash;
	my $pad = $len - length($t) -3;
	$pad < 8 and die;
	return "\x00\x01" . ("\xff" x $pad) . "\x00" . $t;
    }

}

sub _verify_sig {
    my ($self,$sig,$param) = @_;
    return (DKIM_PERMFAIL,"none or invalid dkim record") if ! %$param;
    return (DKIM_TEMPFAIL,$param->{tempfail}) if $param->{tempfail};
    return (DKIM_PERMFAIL,$param->{permfail}) if $param->{permfail};

    my $FAIL = $param->{t}{y} ? DKIM_SOFTFAIL : DKIM_PERMFAIL;
    return ($FAIL,"key revoked") if ! $param->{p};

    return ($FAIL,"hash algorithm not allowed")
	if ! $param->{h}{$sig->{'a:hash'}};

    return ($FAIL,"identity does not match domain") if $param->{t}{s}
	&& $sig->{'i:domain'} && $sig->{'i:domain'} ne $sig->{d};

    return ($FAIL,"identity does not match granularity")
	if $param->{g} && $sig->{i} !~ $param->{g};

    # pre-computed hash over body
    if ($sig->{'bh:computed'} ne $sig->{'bh:bin'}) {
	return ($FAIL,'body hash mismatch');
    }

    my $rsa = Crypt::OpenSSL::RSA->new_public_key(do {
	local $_ = $param->{p};
	s{\s+}{}g;
	s{(.{1,64})}{$1\n}g;
	"-----BEGIN PUBLIC KEY-----\n$_-----END PUBLIC KEY-----\n";
    });
    $rsa or return ($FAIL,"using public key failed");
    $rsa->use_no_padding;
    my $bencrypt = $rsa->encrypt($sig->{'b:bin'});
    my $expect = _emsa_pkcs1_v15(
	$sig->{'a:hash'},$sig->{'h:hash'},$rsa->size);
    if ($expect ne $bencrypt) {
	# warn "expect= "._encode64($expect)."\n";
	# warn "encrypt="._encode64($bencrypt)."\n";
	return ($FAIL,'header sig mismatch');
    }
    return (DKIM_SUCCESS);
}

sub _parse_header {
    my ($self,$hdr) = @_;

    while ( $self->{extract_sig}
	&& $hdr =~m{^(DKIM-Signature:\s*(.*\n(?:[ \t].*\n)*))}mig ) {

	my $dkh = $1; # original value to exclude it when computing hash

	my $error;
	my $sig = parse_signature($2,\$error) or do {
	    push @{$self->{sig}},{
		error => "invalid DKIM-Signature header: $error",
	    };
	    next;
	};

	$sig->{'h:hash'} = _compute_hdrhash($hdr,
	    $sig->{'h:list'},$sig->{'a:hash'},$sig->{'c:hdr'},$dkh);
	push @{$self->{sig}},$sig;
    }

    $self->{sig} or return;

    1;
}

{

    # simple header canonicalization:
    my $simple_hdrc = sub {
	my $line = shift;
	$line =~s{(?<!\r)\n}{\r\n}g;  # normalize line end
	return $line;
    };

    # relaxed header canonicalization:
    my $relaxed_hdrc = sub {
	my ($k,$v) = shift() =~m{\A([^:]+:[ \t]*)?(.*)\z}s;
	$v =~s{\r?\n([ \t])}{$1}g;  # unfold lines
	$v =~s{[ \t]+}{ }g;      # WSP+ -> SP
	$v =~s{\s+\z}{\r\n};     # eliminate all WS from end, normalize line end
	$k = lc($k||'');         # lower case key
	$k=~s{[ \t]*:[ \t]*}{:}; # remove white-space around colon
	return $k.$v;
    };

    my %hdrc = (
	simple => $simple_hdrc,
	relaxed => $relaxed_hdrc,
    );

    use Digest::SHA;
    my %digest = (
	sha1   => sub { Digest::SHA->new(1) },
	sha256 => sub { Digest::SHA->new(256) },
    );

    sub _compute_hdrhash {
	my ($hdr,$headers,$hash,$canon,$dkh) = @_;
	#warn "XXX $hash | $canon";
	$hash = $digest{$hash}();
	$canon = $hdrc{$canon};
	my @hdr;
	for my $k (@$headers) {
	    if ($k eq 'dkim-signature') {
		for($hdr =~m{^($k:[^\n]*\n(?:[ \t][^\n]*\n)*)}mig) {
		    $_ eq $dkh and next;
		    push @hdr,$_;
		}
	    } else {
		push @hdr, $hdr =~m{^($k:[^\n]*\n(?:[ \t][^\n]*\n)*)}mig;
	    }
	}
	$dkh =~s{([ \t;:]b=)([a-zA-Z0-9/+= \t\r\n]+)}{$1};
	$dkh =~s{[\r\n]+\z}{};
	push @hdr,$dkh;
	$_ = $canon->($_) for (@hdr);
	#warn Dumper(\@hdr); use Data::Dumper;
	$hash->add(@hdr);
	return $hash->digest;
    }

    # simple body canonicalization:
    # - normalize to \r\n line end
    # - remove all empty lines at the end
    # - make sure that body consists at least of a single empty line
    # relaxed body canonicalization:
    # - like simple, but additionally...
    # - remove any white-space at the end of a line (excluding \r\n)
    # - compact any white-space inside the line to a single space

    my $bodyc = sub {
	my $relaxed = shift;
	my $empty = my $no_line_yet = '';
	my $realdata;
	sub {
	    my $data = shift;
	    if ($data eq '') {
		return $no_line_yet if $realdata;
		return "\r\n";
	    }
	    my $nl = rindex($data,"\n");
	    if ($nl == -1) {
		$no_line_yet .= $data;
		return '';
	    }

	    if ($nl == length($data)-1) {
		# newline at end of data
		$data = $no_line_yet . $data if $no_line_yet ne '';
		$no_line_yet = '';
	    } else {
		# newline somewhere inside
		$no_line_yet .= substr($data,0,$nl+1,'');
		($data,$no_line_yet) = ($no_line_yet,$data);
	    }

	    $data =~s{(?<!\r)\n}{\r\n}g; # normalize line ends
	    if ($relaxed) {
		$data =~s{[ \t]+}{ }g;   # compact WSP+ to SP
		$data =~s{ \r\n}{\r\n}g; # remove WSP+ at eol
	    }

	    if ($data =~m{(^|\n)(?:\r\n)+\z}) {
		if (!$+[1]) {
		    # everything empty
		    $empty .= $data;
		    return '';
		} else {
		    # part empty
		    $empty .= substr($data,0,$+[1],'');
		    ($empty,$data) = ($data,$empty);
		}
	    } else {
		# nothing empty
		if ($empty ne '') {
		    $data = $empty . $data;
		    $empty = '';
		}
	    }
	    $realdata = 1;
	    return $data;
	};
    };



    my %bodyc = (
	simple  => sub { $bodyc->(0) },
	relaxed => sub { $bodyc->(1) },
    );

    sub _append_body {
	my ($self,$buf) = @_;
	my $bh = $self->{_bodyhash} ||= do {
	    my @bh;
	    for(@{$self->{sig}}) {
		if ($_->{error}) {
		    push @bh, { done => 1 };
		    next;
		}
		my $digest = $digest{$_->{'a:hash'}}();
		my $transform = $bodyc{$_->{'c:body'}}();
		push @bh, {
		    digest => $digest,
		    transform => $transform,
		    l => $_->{l}
		};
	    }
	    \@bh;
	};

	my $done = 0;
	for(@$bh) {
	    if ($_->{done}) {
		$done++;
		next;
	    }
	    my $tbuf = $_->{transform}($buf);
	    $tbuf eq '' and next;
	    if ($_->{l}) {
		$_->{l} -= length($tbuf);
		if ($_->{l}<=0) {
		    substr($tbuf,$_->{l}) = '' if $_->{l}<0;
		    $_->{done} = 1;
		}
	    }
	    $_->{digest}->add($tbuf);
	}

	if ($done == @$bh or $buf eq '') {
	    # done
	    delete $self->{_bodyhash};
	    for(my $i=0;$i<@$bh;$i++) {
		$self->{sig}[$i]{'bh:computed'} =
		    ( $bh->[$i]{digest} || next)->digest;
	    }
	    $self->{_bhdone} = 1;
	}
    }
}



{
    my $fws = qr{
	[ \t]+ (?:\r?\n[ \t]+)? |
	\r?\n[ \t]+
    }x;
    my $tagname = qr{[a-z]\w*}i;
    my $tval = qr{[\x21-\x3a\x3c-\x7e]+};
    my $tagval = qr{$tval(?:$fws$tval)*};
    my $end = qr{(?:\r?\n)?\z};
    my $delim_or_end = qr{ $fws? (?: $end | ; (?: $fws?$end|)) }x;
    sub _parse_taglist {
	my ($v,$w) = @_;
	my %v;
	while ( $v =~m{\G $fws? (?:
	    ($tagname) $fws?=$fws? ($tagval?) $delim_or_end |
	    | (.+)
	)}xgcs) {
	    if (defined $3) {
		$$w = "invalid data at end: '$3'";
		return;
	    }
	    last if ! defined $1;
	    exists($v{$1}) && do {
		$$w = "duplicate key $1";
		return;
	    };
	    $v{$1} = $2;
	}
	#warn Dumper(\%v); use Data::Dumper;
	return \%v;
    }
}


sub _encode64 {
    my $data = shift;
    my $pad = ( 3 - length($data) % 3 ) % 3;
    $data = pack('u',$data);
    $data =~s{(^.|\n)}{}mg;
    $data =~tr{` -_}{AA-Za-z0-9+/};
    substr($data,-$pad) = '=' x $pad if $pad;
    return $data;
}

sub _decode64 {
    my $data = shift;
    $data =~s{\s+}{}g;
    $data =~s{=+$}{};
    $data =~tr{A-Za-z0-9+/}{`!-_};
    $data =~s{(.{1,60})}{ chr(32 + length($1)*3/4) . $1 . "\n" }eg;
    return unpack("u",$data);
}

sub _encodeQP {
    (my $data = shift)
	=~s{([^\x21-\x3a\x3c\x3e-\x7e])}{ sprintf('=%02X',ord($1)) }esg;
    return $data;
}

sub _decodeQP {
    my $data = shift;
    $data =~s{\s+}{}g;
    $data =~s{=([0-9A-F][0-9A-F])}{ chr(hex($1)) }esg;
    return $data;
}


package Mail::DKIM::Iterator::VerifyRecord;
sub new {
    my $class = shift;
    bless [@_],$class;
}
sub sig       { shift->[0] }
sub domain    { shift->[0]{d} }
sub dnsname   { shift->[1] }
sub status    { shift->[2] }
sub error     { shift->[3] }

package Mail::DKIM::Iterator::SignRecord;
sub new {
    my $class = shift;
    bless [@_],$class;
}
sub sig       { shift->[0] }
sub domain    { shift->[0]{d} }
sub dnsname   {
    my $sig = shift;
    return ($sig->{s} || 'UNKNOWN').'_domainkey'.($sig->{d} || 'UNKNOWN');
}
sub signature { shift->[1] }
sub status    { shift->[2] }
sub error     { shift->[3] }


1;

__END__

=head1 NAME Mail::DKIM::Iterator

Iterativ validation of DKIM records or DKIM signing of mails.

=head1 SYNOPSIS

    # Verify all DKIM signature headers found within a mail
    my $mailfile = $ARGV[0];

    use Mail::DKIM::Iterator;
    use Net::DNS;

    my %dnscache;
    my $res = Net::DNS::Resolver->new;

    # Create a new Mail::DKIM::Iterator object and feed pieces of the mail
    # into it until one gets the feedback that these are enough data to
    # verify the signature.
    # If no usable DKIM-Signature header was found enough means already at
    # the end of the mail header, otherwise it usually needs the full mail
    # (unless there is a length limit for the body in the signature).

    open( my $fh,'<',$mailfile) or die $!;
    my $dkim = Mail::DKIM::Iterator->new(dns => \%dnscache);
    my $rv;
    while (1) {
	if (read($fh,$buf,8192)) {
	    $rv = $dkim->append($buf) and last;
	} else {
	    $rv = $dkim->append('');
	    last;
	}
    }

    # Once all signature headers are found and enough body is read so that
    # the body hash is known we need the DKIM keys found in the DNS. The
    # result we have so far are returned in a VerifyRecord for each
    # DKIM-Signature in the mail header. If $r->status is not yet # defined
    # we need to look up the TXT record and feed it into the
    # Mail::DKIM::Iterator object using
    #   $dkim->verify({ dnsname => $dkim_record }).
    # We do that until all names are resolved or we got error in resolving
    # the name.

    check_rv:
    my $retry = 0;
    my %dns;
    for(@$rv) {
	defined $_->status and next; # got already record
	my $dnsname = $_->dnsname;
	$retry++;
	if (my $q = $res->query($dnsname,'TXT')) {
	    $dns{$dnsname} = [
		map { $_->type eq 'TXT' ? ($_->txtdata) : () }
		$q->answer
	    ];
	} else {
	    $dns{$dnsname} = undef;
	}
    }
    if ($retry) {
	$rv = $dkim->verify(\%dns);
	goto check_rv;
    }

    # This final result consists of a VerifyRecord for each DKIM signature
    # in the header, which provides access to the status. Status is one of
    # of DKIM_SUCCESS, DKIM_PERMFAIL, DKIM_TEMPFAIL, DKIM_SOFTFAIL or
    # DKIM_INVALID_HDR. In case of error $record->error contains a string
    # representation of the error.

    for(@$rv) {
	my $status = $_->status;
	my $name = $_->domain;
	if (!defined $status) {
	    print STDERR "$mailfile: $name UNKNOWN\n";
	} elsif ($status DKIM_SUCCESS) {
	    # fully validated
	    print STDERR "$mailfile: $name OK\n";
	} elsif ($status == DKIM_PERMFAIL) {
	    # hard error
	    print STDERR "$mailfile: $name FAIL ".$_->error."\n";
	} else {
	    # soft-fail, temp-fail, invalid-header
	    print STDERR "$mailfile: $name $status ".$_->error."\n";
	}
    }


    # Create signature for a mail
    my $mailfile = $ARGV[0];

    use Mail::DKIM::Iterator;

    my $dkim = Mail::DKIM::Iterator->new(sign => [{
	c => 'relaxed/relaxed',
	a => 'rsa-sha1',
	d => 'example.com',
	s => 'foobar',
	':key' => ... PEM string for private key or Crypt::OpenSSL::RSA object
    }]);

    open(my $fh,'<',$mailfile) or die $!;
    my $rv;
    while (!$rv || grep { !defined $_->status } @$rv) {
	if (read($fh, my $buf,8192)) {
	    $rv = $dkim->append($buf);
	} else {
	    $rv = $dkim->append('');
	    last;
	}
    }
    for(@$rv) {
	my $status = $_->status;
	my $name = $_->domain;
	if (!defined $status) {
	    print STDERR "$mailfile: $name UNKNOWN\n";
	} elsif (status != DKIM_SUCCESS) {
	    print STDERR "$mailfile: $name $status - ".$_->error."\n";
	} else {
	    # show signature
	    print $_->signature;
	}
    }




=head1 DESCRIPTION

With this module one can validate DKIM Signatures in mails and also create DKIM
signatures for mails.

The main difference to L<Mail::DKIM> is that the validation can be done
iterative, that is the mail can be streamed into the object and if DNS lookups
are necessary their results can be added to the DKIM object asynchronously.
There are no blocking operation or waiting for input, everything is directly
driven by the user/application feeding the DKIM object with data.

This module implements only DKIM according to RFC 6376.
It does not support the historic DomainKeys standard (RFC 4870).

The following methods are relevant.
For details of their use see the examples in the SYNOPSIS.

=over 4

=item new(%args) -> $dkim

This will create a new object. The following arguments are supported

=over 8

=item dns => \%hash

A hash with the DNS name as key and the DKIM record for this name as value.
This can be used as a common DNS cache shared over multiple instances of the
class. If none is given only a local hash will be created inside the object.

=item sign => \@dkim_sig

List of DKIM signatures which should be used for signing the mail (usually only
a single one). These can be given as string or hash (see C<parse_signature>
below). These DKIM signatures are only used to collect the relevant information
from the header and body of the mail, the actual signing is done in the
SignRecord object (see below).

=item sign_and_verify => 0|1

Usually it either signs the mail (if C<sign> is given) or validates signatures
inside the mail. When this option is true it will validate existing signatures
additionally to creating new signatures if C<sign> is used.

=back


=item $dkim->append($buffer) -> $rv

This is used to append a new chunk from the mail.
To signal the end of the mail C<$buffer> should be C<''>.

If more data are needed C<$rv> will be undef.
Otherwise C<$rv> will be a list of result records, one for each DKIM-Signature
record in the mail and in the same order. If no such headers are found this list
is empty. For details of the result records see C<result>.

=item $dkim->result([\%dns]) -> $rv

If C<%dns> is given it will be used to update the internal mappings between DNS
name and DKIM record (see C<new>) which then will be used to update any
record validations. The result will be returned, i.e. undef if still data are
needed from the mail or C<$rv> with a list of records. Each of these records is
either a VerifyRecord (in case of DKIM verification) or a SignRecord (in case of
DKIM signing).

Both VerifyRecord and SignRecord have the following methods:

=over 8

=item status - undef if no DKIM result is yet known for the record. Otherwise
any of DKIM_SUCCESS, DKIM_INVALID_HDR, DKIM_TEMPFAIL, DKIM_SOFTFAIL,
DKIM_PERMFAIL.

=item error - an error description in case the status shows an error, i.e. with
all status values except undef and DKIM_SUCCESS.

=item sig - the DKIM signature as hash

=item domain - the domain value from the DKIM signature

=item dnsname - the dnsname value, i.e. based on domain and selector

=back

A SignRecord has additionally the following methods:

=over 8

=item signature - the DKIM-Signature value, only if DKIM_SUCCESS

=back


If any of the result records contains a status of undef the user should do a DNS
lookup for a TXT record for the name given in the record and feed it back into
the object using C<verify>.

=back

Apart from these methods the following utility functions are provided

=over 4

=item parse_signature($dkim_sig,\$error) -> \%dkim_sig|undef

This parses the value from the DKIM-Signature field of mail and returns it as a
hash. On any problems while interpreting the value undef will be returned and
C<$error> will be filled with a string representation of the problem.

=item parse_dkimkey($dkim_key,\$error) -> \%dkim_key|undef

This parses a DKIM key which is usually found as a TXT record in DNS and
returns it as a hash. On any problems while interpreting the value undef will be
returned and C<$error> will be filled with a string representation of the
problem.

=item sign($dkim_sig,$priv_key,$hdr,\$error) -> $signed_dkim_sig

This takes a DKIM signature C<$dkim_sig> (as string or hash), an RSA private key
C<$priv_key> (as PEM string or Crypt::OpenSSL::RSA object) and the header of the
mail and computes the signature. The result C<$signed_dkim_sig> will be a
signature string which can be put on top of the mail.

On errors $error will be set and undef will returned.

=back

=head1 SEE ALSO

L<Mail::DKIM>

L<Mail::SPF::Iterator>

=head1 AUTHOR

Steffen Ullrich <sullr[at]cpan[dot]org>

=head1 COPYRIGHT

Steffen Ullrich, 2015

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.
