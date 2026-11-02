package Plugins::NetEase::API;

use strict;

use JSON::XS qw(decode_json);
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;

my $prefs = preferences('plugin.netease');
my $log   = logger('plugin.netease');

my $UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
	. '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

# 每批请求的歌曲数量，避免 URL 过长。
use constant BATCH_SIZE => 100;

sub isDirect {
	return ( ( $prefs->get('backend') || 'api' ) eq 'direct' ) ? 1 : 0;
}

sub isLoggedIn {
	my $cookie = $prefs->get('cookie');
	return 0 unless defined $cookie && length $cookie;

	# 只有真正验证过账号（拿到了 profile.userId）才算已登录。
	# 否则“本地有 Cookie 就显示已登录”，会和验证失败的结果自相矛盾。
	return 0 unless $prefs->get('verified');

	return 0 if isDirect && !length( $prefs->get('uid') || '' );

	return 1;
}

sub apiBase {
	my $base = $prefs->get('apiBase') || 'http://127.0.0.1:3000';
	$base =~ s{/+\z}{};
	return $base;
}

sub _url {
	my ( $path, $query ) = @_;

	my $url = ( isDirect ? 'https://music.163.com' : apiBase() ) . $path;

	# NeteaseCloudMusicApi 会把 realIP 作为 X-Real-IP 发给网易云。
	# 容器内默认取到的是私有地址，容易被判定为“设备环境异常”。
	# 只对登录相关接口生效；给数据接口伪造来源 IP 没有收益，反而增加风控风险。
	if ( !isDirect && $path =~ m{^/login/(?:cellphone|qr/)} ) {
		my $realIP = $prefs->get('realIP');

		if ( defined $realIP && $realIP =~ /^[\d.a-fA-F:]+$/ ) {
			$query ||= {};
			$query->{realIP} = $realIP;
		}
	}

	if ( $query && %$query ) {
		my @pairs;
		for my $key ( keys %$query ) {
			my $value = $query->{$key};
			next unless defined $value;
			push @pairs, uri_escape_utf8($key) . '=' . uri_escape_utf8($value);
		}
		$url .= '?' . join( '&', @pairs ) if @pairs;
	}

	return $url;
}

# Set-Cookie 里的属性片段，不能出现在请求 Cookie 头里。
my %COOKIE_ATTR = map { $_ => 1 }
	qw(Max-Age Expires Path Domain HttpOnly Secure SameSite Priority Partitioned Comment Version);

# 浏览器 Cookie 面板或响应头里复制出来的内容往往带着这些属性，
# 直接拼进请求头会让 NCM API 解析不出 MUSIC_U，静默降级成匿名。
sub _strip_cookie_attrs {
	my $raw = shift;

	return '' unless defined $raw && length $raw;

	my ( @order, %values );
	my $bare = 0;

	for my $token ( split /;/, $raw ) {
		$token =~ s/^\s+|\s+$//g;
		next unless length $token;

		my ( $name, $value ) = split /=/, $token, 2;

		unless ( defined $value && length $value ) {
			$bare = 1;
			next;
		}

		next if $COOKIE_ATTR{$name};
		next unless $name =~ /^[\w\-\.\$]{1,40}$/;

		if ( exists $values{$name} ) {
			$values{$name} = $value;
			next;
		}

		push @order, $name;
		$values{$name} = $value;
	}

	# 整段都是裸值（用户只粘贴了 MUSIC_U 的 value）时保持原样交给后续判断。
	return $raw if $bare && !@order;

	my @pairs = map { "$_=$values{$_}" } @order;

	return @pairs ? join( '; ', @pairs ) : $raw;
}

sub normalizeCookie {
	my ( $class, $raw ) = @_;

	return '' unless defined $raw;

	$raw =~ s/\r//g;
	$raw =~ s/^\s+|\s+$//g;
	$raw =~ s/^Cookie\s*:\s*//i;

	# 多行粘贴：能识别成 name=value 的按 Cookie 对拼接；
	# 否则取最长一行（通常是 MUSIC_U 的值）。
	if ( $raw =~ /\n/ ) {
		my @lines = grep { length } split /\n/, $raw;

		if ( grep { /^[A-Za-z0-9_]{1,30}=/ } @lines ) {
			$raw = join '; ', @lines;
		}
		else {
			@lines = sort { length($b) <=> length($a) } @lines;
			$raw   = $lines[0] || '';
		}
	}

	$raw =~ s/\s*;\s*/; /g;

	$raw = _strip_cookie_attrs($raw);

	return '' unless length $raw;

	# NCM API 的 cookie 解析器会丢弃没有 “name=” 的片段。
	# 只粘贴 MUSIC_U 的值（或从表格里复制出来的裸值）时自动补上名字。
	# 注意不能只看 “是否有 =”，base64 值本身可能以 == 结尾。
	my $looks_like_cookie =
		   $raw =~ /(?:^|; )MUSIC_U=/
		|| $raw =~ /^(?:__csrf|NMTID|MUSIC_A|_ntes_nuid|_ntes_nnid|WNMCID|WEVNSM|osver|deviceId|appver|channel|os)=/
		|| ( $raw =~ /;/ && $raw =~ /(?:^|; )[A-Za-z0-9_]{1,30}=/ );

	$raw = 'MUSIC_U=' . $raw unless $looks_like_cookie;

	return $raw;
}

# 把用户粘贴的内容拆成若干“可能的 MUSIC_U Cookie”，供验证时逐个尝试。
# 用户从 DevTools 里可能只复制了值，甚至复制了多行不同的值（MUSIC_A、__csrf 等）。
sub cookieCandidates {
	my ( $class, $raw ) = @_;

	return () unless defined $raw && length $raw;

	$raw =~ s/\r//g;
	$raw =~ s/^\s+|\s+$//g;
	$raw =~ s/^Cookie\s*:\s*//i;

	my @candidates;

	if ( $raw =~ /(?:^|; )MUSIC_U=/ ) {
		@candidates = ( normalizeCookie($raw) );
	}
	else {
		for my $token ( split /[\s;,]+/, $raw ) {
			next if length($token) < 16;
			next if $token =~ /^[A-Za-z0-9_]{1,30}=/;
			push @candidates, 'MUSIC_U=' . $token;
		}
	}

	my %seen;
	@candidates = grep { !$seen{$_}++ } @candidates;

	return @candidates[ 0 .. ( $#candidates > 11 ? 11 : $#candidates ) ];
}

sub _headers {
	my $cookie = shift;

	($cookie) = $prefs->get('cookie') unless defined $cookie;

	$cookie = __PACKAGE__->normalizeCookie($cookie);

	my @headers = (
		'User-Agent' => $UA,
		'Referer'    => 'https://music.163.com/',
		'Accept'     => 'application/json, text/plain, */*',
	);

	push @headers, 'Cookie' => $cookie
		if defined $cookie && length $cookie;

	return @headers;
}

sub _parse {
	my $content = shift;

	return undef unless defined $content && length $content;

	my $data = eval { decode_json($content) };

	if ( $@ || !defined $data ) {
		$log->warn('Invalid JSON from NetEase backend');
		return undef;
	}

	return $data;
}

sub _error_text {
	my $err = shift;

	return 'network error' unless defined $err;

	if ( ref($err) eq 'HASH' ) {
		return $err->{message} || $err->{error} || 'network error';
	}

	return "$err";
}

sub _clean_message {
	my $msg = shift;

	return '' unless defined $msg;

	$msg =~ s{<[^>]+>}{}g;
	$msg =~ s{\s+}{ }g;
	$msg = substr( $msg, 0, 200 );

	return $msg;
}

sub _async {
	my ( $url, $cb, $ecb, $timeout ) = @_;

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $data     = _parse( $response->content );

			unless ($data) {
				$ecb->('invalid JSON response');
				return;
			}

			$cb->($data);
		},
		sub {
			my ( $response, $err ) = @_;
			$ecb->( _error_text($err) );
		},
		{
			timeout => $timeout || 20,
			cache   => 0,
		},
	);

	$http->get( $url, _headers() );
}

sub _sync {
	my ( $url, $timeout, $cookie ) = @_;

	my @headers = _headers($cookie);
	my $seconds = $timeout || 20;

	my ( $code, $content, @setCookies );

	# LMS 自带 LWP 时优先使用；缺失时退回核心模块 HTTP::Tiny。
	if ( eval { require LWP::UserAgent; 1 } ) {
		my $res = LWP::UserAgent->new( timeout => $seconds )->get( $url, @headers );
		$code    = $res->code;
		$content = $res->content;
		@setCookies = $res->headers->header('Set-Cookie');
	}
	else {
		require HTTP::Tiny;
		my $res = HTTP::Tiny->new( timeout => $seconds )
			->get( $url, { headers => {@headers} } );
		$code    = $res->{status};
		$content = $res->{content};
		my $sc = $res->{headers}{'set-cookie'};
		@setCookies = defined $sc ? ($sc) : ();
	}

	my $data = _parse($content);

	unless ( defined $code && $code >= 200 && $code < 300 ) {
		# 后端在 4xx/5xx 时也会返回 JSON（含 msg），尽量把它带给设置页。
		my $detail = '';
		if ( ref($data) eq 'HASH' ) {
			$detail = $data->{msg} || $data->{message} || '';
			$detail = $data->{body}{msg} if !$detail && ref($data->{body}) eq 'HASH';
			$detail = _clean_message($detail);
		}

		# LWP 连不上主机时也会返回 500，正文是不可解析的连接错误。
		# 把这类短文本一并显示，避免所有网络问题都只报 “HTTP 500”。
		if ( !$detail && !$data && defined $content && length $content
			&& $content !~ /^\s*</ )
		{
			$detail = _clean_message($content);
		}

		my $err = 'HTTP ' . ( $code || 'error' );
		$err .= ": $detail" if length $detail;

		my $label = $url;
		$label =~ s/\?.*//;

		$log->warn("NetEase backend request failed: $err ($label)");

		return ( undef, $err, \@setCookies );
	}

	unless ($data) {
		return ( undef, 'invalid JSON response', \@setCookies );
	}

	return ( $data, undef, \@setCookies );
}

sub _cookie_from {
	my ( $data, $setCookies ) = @_;

	my $raw;

	if ( ref($data) eq 'HASH' && defined $data->{cookie} && length $data->{cookie} ) {
		$raw = $data->{cookie};
	}
	elsif ( ref($setCookies) eq 'ARRAY' ) {
		my @pairs;
		for my $line ( @$setCookies ) {
			next unless defined $line;
			if ( $line =~ /^\s*([^=;,\s]+)=([^;]*)/ ) {
				push @pairs, "$1=$2";
			}
		}
		$raw = join( '; ', @pairs ) if @pairs;
	}

	return undef unless defined $raw && length $raw;

	# 扫码登录时后端返回的 cookie 字段是把 Set-Cookie 原始行拼起来的，
	# 会带上 Max-Age/Expires/Path 等属性。存进 prefs 前先净化，
	# 否则后续请求会因属性污染解析不出 MUSIC_U，被静默降级成匿名。
	my $cookie = __PACKAGE__->normalizeCookie($raw);

	return length($cookie) ? $cookie : undef;
}

sub loginCellphoneSync {
	my ( $class, $phone, $password, $captcha ) = @_;

	return ( undef, 'phone/password login requires the API backend' )
		if isDirect;

	return ( undef, 'missing phone number or password' )
		unless defined $phone && length $phone && defined $password && length $password;

	# 容忍用户输入的空格、连字符和 +86 前缀，后端只接受纯号码。
	$phone =~ s/\D//g;
	$phone =~ s/^86(1\d{10})$/$1/;

	return ( undef, 'invalid phone number' )
		unless $phone =~ /^1\d{10}$/;

	my $query = {
		phone     => $phone,
		password  => $password,
		timestamp => time(),
	};
	$query->{captcha} = $captcha if defined $captcha && length $captcha;

	my ( $data, $err, $res ) = _sync(
		_url( '/login/cellphone', $query ),
		30,
	);

	return ( undef, $err ) if $err;

	my $code    = $data->{code} || 0;
	my $profile = $data->{profile} || $data->{account};

	# 登录成功
	if ( $code == 200 && $profile ) {
		my $cookie = _cookie_from( $data, $res );

		return ( undef, 'login succeeded but no cookie was returned' )
			unless $cookie;

		return (
			{
				cookie   => $cookie,
				uid      => $profile->{userId},
				nickname => $profile->{nickname},
			},
			undef,
		);
	}

	# 网易云要求图形验证码：code 可能是 200，但没有 profile，
	# 响应里带 img（base64 验证码图片）。此时需要用户看图填码再重试。
	my $img = $data->{img}
		|| ( ref( $data->{data} ) eq 'HASH' ? $data->{data}{img} : undef );

	if ($img) {
		return ( undef, 'captcha_required', { img => $img } );
	}

	if ( $code != 200 ) {
		my $msg = $data->{msg} || $data->{message} || "login failed (code $code)";

		# 网易云后端对手机号格式错误只返回裸 code:400，没有 msg。
		$msg = '手机号格式无效，请填写 11 位大陆手机号'
			if $code == 400 && !$data->{msg} && !$data->{message};

		return ( undef, _clean_message($msg) );
	}

	return ( undef, 'login failed: unexpected response' );
}

# 扫码登录：先取 unikey，再生成二维码图片，最后轮询/手动检查扫码结果。
sub qrCreateSync {
	my $class = shift;

	return ( undef, 'QR login requires the API backend' ) if isDirect;

	my ( $keyData, $err ) = _sync(
		_url( '/login/qr/key', { timestamp => time() } ),
		20,
	);

	return ( undef, $err ) if $err;

	my $key = $keyData->{data}{unikey} || $keyData->{unikey};

	unless ($key) {
		return ( undef, _clean_message( $keyData->{msg} || 'no QR key returned' ) );
	}

	my ( $qrData, $qrErr ) = _sync(
		_url( '/login/qr/create', {
			key       => $key,
			qrimg     => 'true',
			timestamp => time(),
		} ),
		20,
	);

	return ( undef, $qrErr ) if $qrErr;

	my $qr = $qrData->{data} || {};

	unless ( $qr->{qrimg} ) {
		return ( undef, _clean_message( $qrData->{msg} || 'no QR image returned' ) );
	}

	return ( { key => $key, image => $qr->{qrimg}, url => $qr->{qrurl} }, undef );
}

# 返回 ( { status => waiting|scanned|expired } ) 或
# ( { cookie => ..., uid => ..., nickname => ... } )。
sub qrCheckSync {
	my ( $class, $key ) = @_;

	return ( undef, 'missing QR key' ) unless defined $key && length $key;

	my ( $data, $err ) = _sync(
		_url( '/login/qr/check', { key => $key, timestamp => time() } ),
		20,
	);

	return ( undef, $err ) if $err;

	my $code = $data->{code} || 0;
	my %status = (
		800 => 'expired',
		801 => 'waiting',
		802 => 'scanned',
	);

	return ( { status => $status{$code} || "code $code" }, undef ) if $status{$code};

	if ( $code == 803 ) {
		my $cookie = _cookie_from($data);

		return ( undef, 'login succeeded but no cookie was returned' )
			unless $cookie;

		my ($info) = $class->loginStatusSync($cookie);

		return (
			{
				cookie   => $cookie,
				uid      => $info ? $info->{uid}      : undef,
				nickname => $info ? $info->{nickname} : undef,
			},
			undef,
		);
	}

	return ( undef, _clean_message( $data->{msg} || "QR check failed (code $code)" ) );
}

sub loginStatusSync {
	my ( $class, $cookieOverride, $uidOverride ) = @_;

	if ( isDirect ) {
		my $uid = defined $uidOverride && length $uidOverride
			? $uidOverride
			: $prefs->get('uid');

		return ( undef, 'user id is required in direct mode' )
			unless defined $uid && length $uid;

		# 直连模式没有一个稳定的“当前登录用户”接口，这里以能否取到
		# 该 uid 的歌单作为最佳努力校验。公开歌单在未登录时也可能返回，
		# 因此这一步只能证明 uid 有效，不能严格证明 Cookie 有效。
		my ( $pl, $plErr ) = _sync(
			_url( '/api/user/playlist', {
				uid    => $uid,
				limit  => 1,
				offset => 0,
			} ),
			20,
			$cookieOverride,
		);

		if ( !$plErr && ref( $pl->{playlist} ) eq 'ARRAY' ) {
			return (
				{
					uid      => $uid,
					nickname => $prefs->get('nickname') || $uid,
				},
				undef,
			);
		}

		return ( undef, _clean_message( $plErr || 'verification failed' ) );
	}

	my ( $data, $err ) = _sync(
		_url( '/login/status', { timestamp => time() } ),
		20,
		$cookieOverride,
	);

	return ( undef, $err ) if $err;

	my $root    = $data->{data} || {};
	my $profile = $root->{profile} || $data->{profile};

	# 只认 profile.userId。Enhanced 版在未登录时也会返回一个 type=1000 的匿名
	# account（自带 id），拿 account.id 兜底会把“未登录”误判成登录成功。
	my $uid = ref($profile) eq 'HASH' ? $profile->{userId} : undef;

	# NeteaseCloudMusicApi 的 /login/status 返回
	# { data: { code: 200, account: {...}, profile: {...} } }，
	# 顶层没有 code。只看顶层 code 会把成功误判成未登录。
	my $status = $root->{code} || $data->{code} || 0;

	$log->info(
		'NetEase login/status: code='
			. $status
			. ', uid='
			. ( $uid || '-' )
			. ', cookie_len='
			. length( $cookieOverride || $prefs->get('cookie') || '' )
	);

	if ( $uid && ( $status == 200 || !$data->{code} ) ) {
		return (
			{
				uid      => $uid,
				nickname => $profile->{nickname},
			},
			undef,
		);
	}

	return ( undef, _clean_message( $data->{msg} || $root->{msg} || 'not logged in' ) );
}

sub getUserPlaylists {
	my ( $class, $cb, $ecb ) = @_;

	my $uid = $prefs->get('uid');

	unless ( defined $uid && length $uid ) {
		if ( !isDirect && length( $prefs->get('cookie') || '' ) ) {
			my ( $info, $err ) = $class->loginStatusSync;

			if ( $info && $info->{uid} ) {
				$uid = $info->{uid};
				$prefs->set( 'uid', $uid );
				$prefs->set( 'verified', 1 );
				$prefs->set( 'nickname', $info->{nickname} )
					if defined $info->{nickname};
			}
		}
	}

	unless ( defined $uid && length $uid ) {
		$ecb->('user id is missing; verify the account in settings');
		return;
	}

	my $url = isDirect
		? _url( '/api/user/playlist', { uid => $uid, limit => 1000, offset => 0 } )
		: _url( '/user/playlist', { uid => $uid, limit => 1000, offset => 0, timestamp => time() } );

	_async(
		$url,
		sub {
			my $data = shift;

			unless ( ref( $data->{playlist} ) eq 'ARRAY' ) {
				$ecb->( _clean_message( $data->{msg} || 'unexpected playlist response' ) );
				return;
			}

			my @out;
			for my $pl ( @{ $data->{playlist} } ) {
				next unless ref($pl) eq 'HASH' && $pl->{id};

				push @out, {
					id          => $pl->{id},
					name        => $pl->{name} || '',
					coverImgUrl => $pl->{coverImgUrl} || $pl->{coverImgURL} || '',
					trackCount  => $pl->{trackCount} || 0,
					# 5 = “我喜欢的音乐”。直连模式靠它定位红心歌单。
					specialType => $pl->{specialType} || 0,
				};
			}

			$cb->( \@out );
		},
		$ecb,
	);
}

# 取歌单曲目；$offset/$limit 用于分页（/playlist/track/all 支持 offset/limit）。
sub getPlaylistTracks {
	my ( $class, $id, $cb, $ecb, $offset, $limit ) = @_;

	$offset = 0 unless defined $offset && $offset > 0;
	$limit  = 1000 unless defined $limit && $limit > 0;

	if ( !isDirect ) {
		_async(
			_url( '/playlist/track/all', {
				id        => $id,
				limit     => $limit,
				offset    => $offset,
				timestamp => time(),
			} ),
			sub {
				my $data  = shift;
				my $songs = $data->{songs};

				if ( ref($songs) eq 'ARRAY' && @$songs ) {
					$cb->( [ map { _normalize_track($_) } @$songs ] );
					return;
				}

				# 非首页为空说明已经取到末尾，不用再回退到完整详情。
				if ( $offset > 0 ) {
					$cb->( [] );
					return;
				}

				_playlist_detail_slice( $id, $cb, $ecb, $offset, $limit );
			},
			sub {
				if ( $offset > 0 ) {
					$cb->( [] );
					return;
				}

				_playlist_detail_slice( $id, $cb, $ecb, $offset, $limit );
			},
		);
	}
	else {
		_playlist_detail_slice( $id, $cb, $ecb, $offset, $limit );
	}
}

# 整单下载用：逐页拉取直到取完，避免歌单超过 1000 首时被截断。
sub getAllPlaylistTracks {
	my ( $class, $id, $cb, $ecb ) = @_;

	if (isDirect) {
		return _playlist_detail( $id, $cb, $ecb );
	}

	my @all;
	my $offset = 0;
	my $limit  = 1000;

	my $next;
	$next = sub {
		_async(
			_url( '/playlist/track/all', {
				id        => $id,
				limit     => $limit,
				offset    => $offset,
				timestamp => time(),
			} ),
			sub {
				my $data  = shift;
				my $songs = $data->{songs};

				unless ( ref($songs) eq 'ARRAY' ) {
					@all
						? $cb->( [@all] )
						: _playlist_detail( $id, $cb, $ecb );
					return;
				}

				my $count = scalar @$songs;
				push @all, map { _normalize_track($_) } @$songs;

				if ( $count >= $limit ) {
					$offset += $limit;
					$next->();
					return;
				}

				$cb->( [@all] );
			},
			sub {
				@all
					? $cb->( [@all] )
					: _playlist_detail( $id, $cb, $ecb );
			},
		);
	};

	$next->();
}

sub _playlist_detail_slice {
	my ( $id, $cb, $ecb, $offset, $limit ) = @_;

	_playlist_detail(
		$id,
		sub { $cb->( _slice_tracks( shift, $offset, $limit ) ) },
		$ecb,
	);
}

sub _slice_tracks {
	my ( $tracks, $offset, $limit ) = @_;

	$tracks ||= [];
	$offset = 0 unless defined $offset && $offset > 0;
	$limit  = scalar @$tracks unless defined $limit && $limit > 0;

	my $total = scalar @$tracks;
	my $start = $offset > $total ? $total : $offset;
	my $count = $limit;
	$count = $total - $start if $start + $count > $total;

	return [] if $count <= 0;

	return [ @$tracks[ $start .. $start + $count - 1 ] ];
}

sub _playlist_detail {
	my ( $id, $cb, $ecb ) = @_;

	_async(
		_url( isDirect ? '/api/v6/playlist/detail' : '/playlist/detail', {
			id        => $id,
			timestamp => time(),
		} ),
		sub {
			my $data = shift;
			my $pl   = $data->{playlist} || {};

			my $tracks = $pl->{tracks};
			my $ids    = $pl->{trackIds};
			my $count  = $pl->{trackCount} || 0;

			my @trackIds = ref($ids) eq 'ARRAY'
				? map { ref($_) eq 'HASH' ? $_->{id} : $_ } @$ids
				: ();

			if ( ref($tracks) eq 'ARRAY' && @$tracks
				&& !@trackIds ) {
				$cb->( [ map { _normalize_track($_) } @$tracks ] );
				return;
			}

			if ( @trackIds ) {
				_song_details( \@trackIds, $cb, $ecb );
				return;
			}

			if ( ref($tracks) eq 'ARRAY' && @$tracks ) {
				$cb->( [ map { _normalize_track($_) } @$tracks ] );
				return;
			}

			$cb->( [] );
		},
		$ecb,
	);
}

sub _song_details {
	my ( $ids, $cb, $ecb ) = @_;

	unless ( @$ids ) {
		$cb->( [] );
		return;
	}

	my @all;
	my $index = 0;

	my $next;
	$next = sub {
		if ( $index >= @$ids ) {
			$cb->( [ map { _normalize_track($_) } @all ] );
			return;
		}

		my $end = $index + BATCH_SIZE - 1;
		$end = $#$ids if $end > $#$ids;

		my @chunk = @$ids[ $index .. $end ];
		$index = $end + 1;

		my $param = isDirect
			? '[' . join( ',', @chunk ) . ']'
			: join( ',', @chunk );

		_async(
			_url( isDirect ? '/api/song/detail' : '/song/detail', {
				ids       => $param,
				timestamp => time(),
			} ),
			sub {
				my $data = shift;
				push @all, @{ $data->{songs} || [] };
				$next->();
			},
			$ecb,
		);
	};

	$next->();
}

sub getSongDetails {
	my ( $class, $ids, $cb, $ecb ) = @_;

	_song_details( $ids, $cb, $ecb );
}

sub _normalize_track {
	my $t = shift;

	my $artists = $t->{ar} || $t->{artists} || [];
	my $album   = $t->{al} || $t->{album} || {};
	my $ms      = $t->{dt} || $t->{duration} || 0;

	my $seconds = $ms;
	$seconds = int( $ms / 1000 ) if $ms > 10000;

	my @artistNames;
	for my $a ( @$artists ) {
		next unless ref($a) eq 'HASH';
		my $name = $a->{name} || $a->{nickname} || '';
		push @artistNames, { name => $name } if length $name;
	}

	return {
		id       => $t->{id},
		name     => $t->{name} || '',
		artist   => \@artistNames,
		album    => $album->{name} || '',
		cover    => $album->{picUrl} || '',
		duration => $seconds,
		fee      => $t->{fee},
	};
}

# 每日推荐。需要登录，直连模式没有对应接口。
sub getDailySongs {
	my ( $class, $cb, $ecb ) = @_;

	unless (isLoggedIn) {
		$ecb->('login_required');
		return;
	}

	if (isDirect) {
		$ecb->('unsupported_backend');
		return;
	}

	_async(
		_url( '/recommend/songs', { timestamp => time() } ),
		sub {
			my $data  = shift;
			my $inner = ref( $data->{data} ) eq 'HASH' ? $data->{data} : {};
			my $songs = $inner->{dailySongs};

			$songs = $data->{recommend} unless ref($songs) eq 'ARRAY';

			unless ( ref($songs) eq 'ARRAY' && @$songs ) {
				$ecb->('empty_result');
				return;
			}

			$cb->( [ map { _normalize_track($_) } @$songs ] );
		},
		$ecb,
	);
}

# 红心歌曲（“我喜欢的音乐”）。
# 返回红心歌曲的完整 id 列表。红心可能有几千首，菜单侧按页取，
# 避免一次性请求全部歌曲详情。
sub getLikedSongIds {
	my ( $class, $cb, $ecb ) = @_;

	unless (isLoggedIn) {
		$ecb->('login_required');
		return;
	}

	# 直连模式没有 /likelist，退化为从歌单列表里找 specialType == 5 的歌单。
	if (isDirect) {
		return $class->getUserPlaylists(
			sub {
				my $playlists = shift;
				my ($liked) = grep { ( $_->{specialType} || 0 ) == 5 } @$playlists;

				unless ($liked) {
					$ecb->('empty_result');
					return;
				}

				_playlist_detail(
					$liked->{id},
					sub {
						my $tracks = shift;
						my @ids = grep { defined && length } map { $_->{id} } @$tracks;

						@ids ? $cb->( \@ids ) : $ecb->('empty_result');
					},
					$ecb,
				);
			},
			$ecb,
		);
	}

	my $uid = $prefs->get('uid');

	unless ( defined $uid && length $uid ) {
		$ecb->('login_required');
		return;
	}

	_async(
		_url( '/likelist', { uid => $uid, timestamp => time() } ),
		sub {
			my $data = shift;
			my $ids  = $data->{ids};

			$ids = $data->{data}{ids}
				if ref( $data->{data} ) eq 'HASH' && ref($ids) ne 'ARRAY';

			unless ( ref($ids) eq 'ARRAY' && @$ids ) {
				$ecb->('empty_result');
				return;
			}

			$cb->($ids);
		},
		$ecb,
	);
}

# 取红心歌曲详情；$offset/$limit 指定分页，回调收到 (tracks, total)。
sub getLikedSongs {
	my ( $class, $cb, $ecb, $offset, $limit ) = @_;

	$offset = 0 unless defined $offset && $offset > 0;
	$limit  = undef unless defined $limit && $limit > 0;

	$class->getLikedSongIds(
		sub {
			my $ids   = shift;
			my $total = scalar @$ids;

			my $start = $offset > $total ? $total : $offset;
			my $count = defined $limit ? $limit : $total - $start;
			$count = $total - $start if $start + $count > $total;

			if ( $count <= 0 ) {
				$cb->( [], $total );
				return;
			}

			_song_details(
				[ @$ids[ $start .. $start + $count - 1 ] ],
				sub { $cb->( shift, $total ) },
				$ecb,
			);
		},
		$ecb,
	);
}

# 推荐新歌（公开接口，不需要登录）。
sub getNewSongs {
	my ( $class, $cb, $ecb ) = @_;

	if (isDirect) {
		$ecb->('unsupported_backend');
		return;
	}

	_async(
		_url( '/personalized/newsong', { limit => 30, timestamp => time() } ),
		sub {
			my $data  = shift;
			my $items = $data->{result};

			unless ( ref($items) eq 'ARRAY' && @$items ) {
				$ecb->('empty_result');
				return;
			}

			my @tracks;

			for my $item (@$items) {
				next unless ref($item) eq 'HASH';

				my $song = ref( $item->{song} ) eq 'HASH' ? $item->{song} : $item;

				next unless $song->{id};

				my $track = _normalize_track($song);

				$track->{cover} = $item->{picUrl}
					if !length( $track->{cover} || '' ) && defined $item->{picUrl};

				push @tracks, $track;
			}

			unless (@tracks) {
				$ecb->('empty_result');
				return;
			}

			$cb->( \@tracks );
		},
		$ecb,
	);
}

# 在线搜索歌曲（公开接口，未登录也能用，只是结果受限）。
sub searchSongs {
	my ( $class, $keywords, $cb, $ecb ) = @_;

	$keywords = '' unless defined $keywords;
	$keywords =~ s/^\s+|\s+$//g;

	unless (length $keywords) {
		$ecb->('empty_keyword');
		return;
	}

	if (isDirect) {
		$ecb->('unsupported_backend');
		return;
	}

	_async(
		_url( '/cloudsearch', {
			keywords  => $keywords,
			type      => 1,
			limit     => 30,
			offset    => 0,
			timestamp => time(),
		} ),
		sub {
			my $data   = shift;
			my $result = ref( $data->{result} ) eq 'HASH' ? $data->{result} : {};
			my $songs  = $result->{songs};

			unless ( ref($songs) eq 'ARRAY' && @$songs ) {
				$ecb->('empty_result');
				return;
			}

			$cb->( [ map { _normalize_track($_) } @$songs ] );
		},
		$ecb,
	);
}

sub getSongUrls {
	my ( $class, $ids, $cb, $ecb, $level ) = @_;

	unless ( ref($ids) eq 'ARRAY' && @$ids ) {
		$cb->( {} );
		return;
	}

	$level ||= $prefs->get('quality') || 'exhigh';

	my @levels    = _level_chain($level);
	my $requested = $levels[0];

	my %out;
	my $index           = 0;
	my $fallback_logged = 0;

	my $next;
	$next = sub {
		if ( $index >= @$ids ) {
			$cb->( \%out );
			return;
		}

		my $end = $index + BATCH_SIZE - 1;
		$end = $#$ids if $end > $#$ids;

		my @chunk = @$ids[ $index .. $end ];
		$index = $end + 1;

		my $li = 0;

		my $fetch;
		$fetch = sub {
			my $current = $levels[$li];

			# 已经拿到地址的歌曲不再重复请求；只补音质不足（url 为空）的那些，
			# 这样无损账号权限不够时会自动降一档，而不是直接播放失败。
			my @pending = grep {
				!defined $out{$_} || !length( $out{$_}->{url} || '' )
			} @chunk;

			unless (@pending) {
				$next->();
				return;
			}

			my $url = isDirect
				? _url( '/api/song/enhance/player/url', {
					ids       => '[' . join( ',', @pending ) . ']',
					br        => _bitrate($current),
					timestamp => time(),
				} )
				: _url( '/song/url/v1', {
					id        => join( ',', @pending ),
					level     => $current,
					timestamp => time(),
				} );

			_async(
				$url,
				sub {
					my $data = shift;

					unless ( ref( $data->{data} ) eq 'ARRAY' ) {
						$ecb->( _clean_message( $data->{msg} || 'unexpected song URL response' ) );
						return;
					}

					for my $u ( @{ $data->{data} } ) {
						next unless ref($u) eq 'HASH' && defined $u->{id};

						$out{ $u->{id} } = {
							id            => $u->{id},
							url           => _https_url( $u->{url} ),
							br            => $u->{br},
							code          => $u->{code},
							fee           => $u->{fee},
							freeTrialInfo => $u->{freeTrialInfo},
							reason        => _url_reason($u),
							level         => $current,
						};
					}

					$li++;

					if ( $li <= $#levels ) {
						$fetch->();
						return;
					}

					my @degraded = grep {
						defined $out{$_} && length( $out{$_}->{url} || '' )
							&& ( $out{$_}->{level} || '' ) ne $requested
					} @chunk;

					if ( @degraded && !$fallback_logged ) {
						$fallback_logged = 1;
						$log->info( "Quality $requested is unavailable for this account,"
							. ' fell back to a lower quality for '
							. scalar(@degraded) . ' track(s)' );
					}

					my @still = grep {
						!defined $out{$_} || !length( $out{$_}->{url} || '' )
					} @chunk;

					if (@still) {
						$log->info( 'No stream URL at any quality ('
							. join( '/', @levels ) . ') for ' . scalar(@still)
							. ' track(s) in this batch' );
					}

					$next->();
				},
				$ecb,
			);
		};

		$fetch->();
	};

	$next->();
}

# 音质降级顺序：高清无损 → 极高 → 较高 → 标准。
my @QUALITY_LEVELS = qw(lossless exhigh higher standard);

# 供播放层在探测失败时按同一顺序换档重试。
sub qualityChain {
	my ( $class, $level ) = @_;

	return _level_chain($level);
}

sub _level_chain {
	my $level = shift;

	my $start = 1;
	for my $i ( 0 .. $#QUALITY_LEVELS ) {
		if ( $QUALITY_LEVELS[$i] eq ( $level || '' ) ) {
			$start = $i;
			last;
		}
	}

	return @QUALITY_LEVELS[ $start .. $#QUALITY_LEVELS ];
}

sub getSongUrl {
	my ( $class, $id, $cb, $ecb, $level ) = @_;

	getSongUrls(
		$class,
		[$id],
		sub {
			my $urls = shift;
			$cb->( $urls->{$id} );
		},
		$ecb,
		$level,
	);
}

sub _https_url {
	my $url = shift;

	return undef unless defined $url && length $url;

	# 网易云音频 CDN 同时支持 https，统一成 https 以便复用 LMS 的
	# HTTPS 协议处理器。
	$url =~ s{^http://}{https://};

	return $url;
}

sub _bitrate {
	my $level = shift;

	return 999000 if defined $level && $level eq 'lossless';
	return 320000 if defined $level && $level eq 'exhigh';
	return 192000 if defined $level && $level eq 'higher';
	return 128000;
}

sub _url_reason {
	my $u = shift;

	my $url = $u->{url};

	if ( !defined $url || !length $url ) {
		my $fee  = $u->{fee} || 0;
		my $code = $u->{code} || 0;

		return 'trial' if $u->{freeTrialInfo};
		return 'auth' if $code == -110;
		return 'not_found' if $code == 404;
		return 'vip' if $fee == 1 || $fee == 4;
		return 'copyright' if $fee == 0;
		return 'url_empty';
	}

	return undef;
}

sub urlReason {
	my $u = shift;

	return _url_reason($u);
}

sub logout {
	my ( $class, $cb ) = @_;

	$cb ||= sub {};

	return $cb->() if isDirect || !length( $prefs->get('cookie') || '' );

	_async(
		_url( '/logout', { timestamp => time() } ),
		sub { $cb->() },
		sub { $cb->() },
		10,
	);
}

1;

__END__

=head1 NAME

Plugins::NetEase::API - 网易云接口封装

=head1 DESCRIPTION

默认通过 NeteaseCloudMusicApi（Node.js）访问网易云；也可以切换为实验性的
直连模式，直接请求 music.163.com 的网页接口。所有 Cookie 均从插件首选项
读取，不写入日志。

=cut
