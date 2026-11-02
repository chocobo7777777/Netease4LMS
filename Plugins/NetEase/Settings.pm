package Plugins::NetEase::Settings;

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $prefs = preferences('plugin.netease');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_NETEASE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/NetEase/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(
		backend apiBase realIP cookie uid quality downloadDir downloadQuality
	));
}

sub handler {
	my ( $class, $client, $params ) = @_;

	require Plugins::NetEase::API;

	my $oldCookie = Plugins::NetEase::API->normalizeCookie(
		$prefs->get('cookie') || ''
	);
	my $oldUid      = $prefs->get('uid')      || '';
	my $oldNickname = $prefs->get('nickname') || '';

	if ( $params->{loginCellphone} ) {
		$params->{saveSettings} = 1;

		if ( Plugins::NetEase::API->isDirect ) {
			$params->{warning} = string('PLUGIN_NETEASE_DIRECT_ONLY_COOKIE');
			$params->{pref_cookie}   = $oldCookie;
			$params->{pref_uid}      = $oldUid;
			$params->{pref_nickname} = $oldNickname;
		}
		else {
			my ( $info, $err, $captcha ) = Plugins::NetEase::API->loginCellphoneSync(
				$params->{phone}, $params->{password}, $params->{captcha}
			);

			if ($info) {
				$params->{pref_cookie} = $info->{cookie};
				$params->{pref_uid}    = $info->{uid} || '';
				$prefs->set( 'nickname', $info->{nickname} || '' );
				$prefs->set( 'verified', 1 );
				$prefs->set( 'captchaImage', '' );
				$params->{warning} = string('PLUGIN_NETEASE_LOGIN_OK');
				$prefs->set( 'qrKey',   '' );
				$prefs->set( 'qrImage', '' );
			}
			elsif ( $captcha && $captcha->{img} ) {
				# 验证码挑战：把图片存到 prefs，渲染时读出，然后清空（一次性）。
				$prefs->set( 'captchaImage', $captcha->{img} );
				$params->{warning} = string('PLUGIN_NETEASE_CAPTCHA_REQUIRED');
				$params->{neteaseLoginMode} = 'phone';
				$params->{pref_cookie} = $oldCookie;
				$params->{pref_uid}    = $oldUid;
				$prefs->set( 'nickname', $oldNickname );
			}
			else {
				$params->{warning} = string('PLUGIN_NETEASE_LOGIN_FAILED')
					. ' ' . ( $err || '' );
				$params->{pref_cookie} = $oldCookie;
				$params->{pref_uid}    = $oldUid;
				$prefs->set( 'nickname', $oldNickname );
				$prefs->set( 'verified', 0 );
			}
		}

		# 密码和验证码只在内存中使用，不出现在 prefs 名称中，因此不会被保存。
		delete $params->{password};
		delete $params->{captcha};
	}
	elsif ( $params->{verifyLogin} ) {
		$params->{saveSettings} = 1;

		my @candidates = Plugins::NetEase::API->cookieCandidates(
			 $params->{pref_cookie}
		);

		my ( $info, $err );
		my $cookie;

		for my $candidate (@candidates) {
			( $info, $err ) = Plugins::NetEase::API->loginStatusSync(
				$candidate, $params->{pref_uid}
			);

			if ($info) {
				$cookie = $candidate;
				last;
			}
		}

		$err ||= 'no MUSIC_U value found';
		$params->{pref_cookie} = $cookie || Plugins::NetEase::API->normalizeCookie(
			$params->{pref_cookie}
		);

		if ($info) {
			$params->{pref_uid} = $info->{uid} if defined $info->{uid};
			$prefs->set( 'nickname', $info->{nickname} )
				if defined $info->{nickname};
			$prefs->set( 'verified', 1 );
			$params->{warning} = string('PLUGIN_NETEASE_VERIFY_OK');
		}
		else {
			$params->{warning} = string('PLUGIN_NETEASE_VERIFY_FAILED')
				. ' ' . ( $err || '' );

			# 验证失败也保留刚粘贴的 Cookie，方便修正后重试；
			# 原来在这里回退成旧值，会把用户唯一的一份 Cookie 清掉。
			$params->{pref_uid} = $oldUid;
			$prefs->set( 'nickname', $oldNickname );
			$prefs->set( 'verified', 0 );
		}
	}
	elsif ( $params->{qrLogin} ) {
		$params->{saveSettings} = 1;

		my ( $qr, $err ) = Plugins::NetEase::API->qrCreateSync;

		if ($qr) {
			$prefs->set( 'qrKey',   $qr->{key} );
			$prefs->set( 'qrImage', $qr->{image} );
			$params->{neteaseQrImage} = $qr->{image};
			$params->{warning} = string('PLUGIN_NETEASE_QR_HINT');
		}
		else {
			$params->{warning} = string('PLUGIN_NETEASE_QR_FAILED')
				. ' ' . ( $err || '' );
		}

		$params->{pref_cookie} = $oldCookie;
		$params->{pref_uid}    = $oldUid;
		$prefs->set( 'nickname', $oldNickname );
	}
	elsif ( $params->{qrCheck} ) {
		$params->{saveSettings} = 1;

		my ( $info, $err ) = Plugins::NetEase::API->qrCheckSync(
			$prefs->get('qrKey')
		);

		if ( $info && $info->{cookie} ) {
			$params->{pref_cookie} = $info->{cookie};
			$params->{pref_uid}    = $info->{uid} || '';
			$prefs->set( 'nickname', $info->{nickname} || '' );
			$prefs->set( 'verified', $info->{uid} ? 1 : 0 );
			$prefs->set( 'qrKey',   '' );
			$prefs->set( 'qrImage', '' );
			$params->{warning} = string('PLUGIN_NETEASE_LOGIN_OK');
		}
		elsif ($info) {
			my %msg = (
				waiting => 'PLUGIN_NETEASE_QR_WAITING',
				scanned => 'PLUGIN_NETEASE_QR_SCANNED',
				expired => 'PLUGIN_NETEASE_QR_EXPIRED',
			);

			my $token = $msg{ $info->{status} || '' } || 'PLUGIN_NETEASE_QR_WAITING';
			$params->{warning} = string($token);

			if ( ( $info->{status} || '' ) eq 'expired' ) {
				$prefs->set( 'qrKey',   '' );
				$prefs->set( 'qrImage', '' );
			}

			$params->{pref_cookie} = $oldCookie;
			$params->{pref_uid}    = $oldUid;
			$prefs->set( 'nickname', $oldNickname );
		}
		else {
			$params->{warning} = string('PLUGIN_NETEASE_QR_FAILED')
				. ' ' . ( $err || '' );
			$params->{pref_cookie} = $oldCookie;
			$params->{pref_uid}    = $oldUid;
			$prefs->set( 'nickname', $oldNickname );
		}
	}
	elsif ( $params->{doLogout} ) {
		$params->{saveSettings} = 1;

		Plugins::NetEase::API->logout;

		$params->{pref_cookie} = '';
		$params->{pref_uid}    = '';
		$prefs->set( 'nickname', '' );
		$prefs->set( 'verified', 0 );
		$prefs->set( 'qrKey',    '' );
		$prefs->set( 'qrImage',  '' );
		$prefs->set( 'captchaImage', '' );
		$params->{warning} = string('PLUGIN_NETEASE_LOGGED_OUT');
	}

	# 密码只在内存中使用，任何分支都不写入 prefs。
	delete $params->{password};

	return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ( $class, $params, $client ) = @_;

	require Plugins::NetEase::API;
	require Plugins::NetEase::Downloader;

	$params->{neteaseLoggedIn} = Plugins::NetEase::API->isLoggedIn ? 1 : 0;

	my $who = $prefs->get('nickname') || $prefs->get('uid') || '';
	$params->{neteaseStatusText} = $params->{neteaseLoggedIn}
		? string('PLUGIN_NETEASE_LOGGED_IN_AS', $who)
		: string('PLUGIN_NETEASE_NOT_LOGGED_IN');

	$params->{neteaseBackend} = $prefs->get('backend') || 'api';

	# 登录方式下拉：默认扫码；用户切换或提交后保持所选方式。
	$params->{neteaseLoginMode} = $params->{neteaseLoginMode} || 'qr';

	my $qrImage = $prefs->get('qrImage') || '';
	$params->{neteaseQrImage} = $qrImage if length $qrImage;

	# 图形验证码：手机号登录被风控时显示，读完即清空（一次性）。
	my $cap = $prefs->get('captchaImage') || '';
	if ( length $cap ) {
		$cap = 'data:image/png;base64,' . $cap unless $cap =~ /^data:/;
		$params->{neteaseCaptchaImage} = $cap;
		$prefs->set( 'captchaImage', '' );
	}

	my $dir = Plugins::NetEase::Downloader->effectiveDir;
	$params->{neteaseEffectiveDir} = $dir
		? string('PLUGIN_NETEASE_EFFECTIVE_DIR', $dir)
		: string('PLUGIN_NETEASE_EFFECTIVE_DIR_NONE');

	$params->{neteaseDirChoices} = [ Plugins::NetEase::Downloader->listDirs ];
}

1;

__END__

=head1 NAME

Plugins::NetEase::Settings - 网易云音乐插件设置页

=cut
