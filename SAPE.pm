=pod
SAPE.ru - Интеллектуальная система купли-продажи ссылок, библиотека на Perl.
Программист: Никита Дедик <meneldor@metallibrary.ru>, ICQ: 23057061
Доработал: Алексей Киреев <_lek@inbox.ru>
Версия для nginx
Базы со ссылками хранятся в /tmp
Вызов из SSI: <!--# perl sub="SHOWSAPE::SHOWLINKS" arg="string sape user" arg="string http_host" arg="string request_uri" arg="bool multisite: O|1" arg="string charset: utf-8i|cp1251" arg="bool verbose: 0|1 " arg="bool force_show_code: 0|1" -->
=cut

# #############################################################################
# SAPE (base) #################################################################
# #############################################################################

package SAPE;
use strict;

our $VERSION = '1.0.3';

BEGIN {
    local $INC{'CGI.pm'} = 1; # пока нет необходимости в модуле CGI, так что эмулируем его наличие
    require CGI::Cookie;
}
use Fcntl qw(:flock :seek);
use File::stat;
use LWP::UserAgent;

use constant {
    SERVER_LIST      => [ qw(dispenser-01.sape.ru dispenser-02.sape.ru) ], # серверы выдачи ссылок SAPE
    CACHE_LIFETIME   => 3600, # время жизни кэша для файлов данных
    CACHE_RELOADTIME => 600, # таймаут до следующего обновления файла, если прошлая попытка не удалась
};

# user            => хэш пользователя SAPE
# host            => (необязательно) имя хоста, для которого выводятся ссылки
# request_uri     => (необязательно) адрес запрашиваемой страницы, по умолчанию: $ENV{REQUEST_URI}
# verbose         => (необязательно) выводить ошибки в HTML-код
# charset         => (необязательно) кодировка для выдачи ссылок: windows-1251 (по умолчанию), utf-8, koi8-r, cp866 и т.д.
# socket_timeout  => (необязательно) таймаут при получении данных от сервера SAPE, по умолчанию: 6
# force_show_code => (необязательно) всегда показывать код SAPE для новых страниц, иначе - только для робота SAPE

sub new {
    my ($class, %args) = @_;

	return SAPE::Client->new(%args) # !!! только для совместимости с SAPE.pm младше версии 1.0 !!!
		if $class eq 'SAPE';

    my $self = bless {
        verbose         => 0,
        charset         => 'windows-1251',
        socket_timeout  => 6,
        force_show_code => 0,
        %args
    }, $class;
    $args{request_uri} ||= $args{uri}; # !!! только для совместимости с SAPE.pm младше версии 1.0 !!!
    !$self->{$_} and die qq|SAPE.pm error: missing parameter "$_" in call to "new"!|
        foreach qw(user host request_uri charset socket_timeout);

    # считать URI со слешом в конце и без него альтернативными
    $self->{request_uri_alt} = substr($self->{request_uri}, -1) eq '/'
        ? substr($self->{request_uri}, $[, -1)
        : $self->{request_uri} . '/';

    # убрать лишнее из имени хоста
    $self->{host} =~ s!^(http://(www\.)?|www\.)!!g;

    # проверяем признаки робота SAPE
    my %cookies = CGI::Cookie->fetch;
    $self->{is_our_bot} = $cookies{sape_cookie} && $cookies{sape_cookie}->value eq $self->{user};

    return $self;
}

sub _load_data {
    my $self = shift;
    my $db_file = $self->_get_db_file;

    local $/ = "\n";

    my $data;

    if (open my $fh, $db_file) {
        # берём кодировку файла данных из шапки файла, сравниваем с запрошенной и помечаем файл для обновления, если совпадения нет
        my $data_charset = <$fh>;
        close $fh;
        chomp $data_charset;
        utime 0, 0, $db_file
            unless $data_charset eq $self->{charset};
    }

    my $stat = -f $db_file ? stat $db_file : undef;
    if (!$stat || $stat->size == 0 || !$self->{is_our_bot} && $stat->mtime < time - CACHE_LIFETIME) {
        # файл не существует или истекло время жизни файла => необходимо загрузить новые данные

        open my $fh, '>>', $db_file
            or return $self->_raise_error("Нет доступа на запись к файлу данных ($db_file): $!. Выставите права 777 на папку.");
        if (flock $fh, LOCK_EX | LOCK_NB) {
            # экслюзивная блокировка файла удалась => можно производить загрузку

            my $ua = LWP::UserAgent->new;
            $ua->agent($self->USER_AGENT . ' ' . $VERSION);
            $ua->timeout($self->{socket_timeout});

            my $data_raw;
            my $path = $self->_get_dispenser_path;
            foreach my $server (@{ &SERVER_LIST }) {
                my $data_url = "http://$server/$path";
                my $response = $ua->get($data_url);
                if ($response->is_success) {
                    $data_raw = $self->{charset} . "\n" . $response->content;
                    return $self->_raise_error($data_raw)
                        if substr($data_raw, $[, 12) eq 'FATAL ERROR:';
                    $data = $self->_parse_data(\$data_raw);
                    last;
                }
            }

            if ($data && $self->_check_data($data)) {
                # данные получены успешно
                seek $fh, 0, SEEK_SET;
                truncate $fh, 0;
                print $fh $data_raw;
                close $fh;
            } else {
                # данные не получены вообще или получены неверные => пометить файл для повторого обновления
                close $fh;
                utime $stat->atime, time - CACHE_LIFETIME + CACHE_RELOADTIME, $db_file
                    if $stat;
            }
        }
    }

    unless ($data) {
        # данные не загружены => загрузить из файла данных
        local $/;
        open my $fh, '<', $db_file
            or return $self->_raise_error("Не удаётся произвести чтение файла данных ($db_file): $!");
        my $data_raw = <$fh>;
        close $fh;
        $data = $self->_parse_data(\$data_raw);
    }

    $self->_set_data($data);

    return;
}

sub _raise_error {
    my ($self, $error) = @_;

    if ($self->{verbose}) {
        eval {
            require Encode;
            Encode::from_to($error, 'utf-8', $self->{charset})
                unless $self->{charset} eq 'windows-1251';
        };
        $self->{_error} = qq|<p style="color: red; font-weight: bold;">SAPE ERROR: $error</p>|;
    }

    return;
}

# #############################################################################
# SAPE::Client ################################################################
# #############################################################################

package SAPE::Client;
use strict;
use base qw(SAPE);

use constant {
    USER_AGENT => 'SAPE_Client Perl',
};

# Вывод ссылок блоками.
# => (необязательно) число ссылок для вывода в этом блоке
# => (необязательно) число ссылок для исключения из вывода
sub return_links {
    my ($self, $limit, $offset) = @_;

    # загрузить данные при первом вызове
    $self->_load_data
        unless defined $self->{_links};
    return $self->{_error}
        if $self->{_error}; # ошибка при загрузке данных

    if (ref $self->{_links_page} eq 'ARRAY') {
        # загружен список ссылок => вывести нужное число
        $limit ||= scalar @{ $self->{_links_page} };
        splice @{ $self->{_links_page} }, $[, $offset
            if $offset;
        return join($self->{_links_delimiter}, splice @{ $self->{_links_page} }, $[, $limit);
    } else {
        # загружен простой текст => вывести его как есть
        return $self->{_links_page};
    }
}

# !!! только для совместимости с SAPE.pm младше версии 1.0 !!!
# count => (необязательно) количество ссылок, которые следует показать (будут удалены из очереди)
sub get_links {
    my ($self, %args) = @_;
    return $self->return_links($args{count});
}

sub _get_db_file {
    my $self = shift;
    return '/tmp/'.$self->{host}.'.'.$self->{user}.'.sape';
}

sub _get_dispenser_path {
    my $self = shift;
    return "code.php?user=$self->{user}&host=$self->{host}&as_txt=true&charset=$self->{charset}&no_slash_fix=true";
}

sub _parse_data {
    my ($self, $data) = @_;

    my $data_parsed = {};
    (undef, undef, $self->{_links_delimiter}, my @pages_raw) = split /\n/, $$data;
    foreach my $page_raw (@pages_raw) {
        my ($page_url, @page_data) = split '\|\|SAPE\|\|', $page_raw;
        $data_parsed->{$page_url} = \@page_data;
    }

    return $data_parsed;
}

sub _check_data {
    my ($self, $data) = @_;
    return defined $data->{__sape_new_url__};
}

sub _set_data {
    my ($self, $data) = @_;
    $self->{_links} = $data;
    $self->{_links_page} = $data->{ $self->{request_uri} } || $data->{ $self->{request_uri_alt} };
    $self->{_links_page} ||= $data->{__sape_new_url__}
        if $self->{is_our_bot} || $self->{force_show_code};
}

# #############################################################################

package SHOWSAPE;
use strict;
use base qw(SAPE);

sub SHOWLINKS {
	my $r = shift;
	$r->send_http_header("text/html");
	(my $user, my $host, my $request_uri, my $multisite, my $charset, my $verbose, my $force_show_code) = @_;
	my $sape = new SAPE::Client(
		'user'			=>	$user,
		'host'			=>	$host || $r->variable('server_name'),
		'request_uri'		=>	$request_uri || $r->variable('request_uri'),
		'multisite'		=>	$multisite,
		'charset'		=>	$charset,
		'verbose'		=>	$verbose,
		'force_show_code'	=>	$force_show_code,
	);
	$r->status(200);
	$r->print($sape->get_links());
	return "OK";
}

1;
