package Canvas::Model::Templates;
use Mojo::Base -base;

use Digest::SHA qw(sha256_hex);
use Mojo::Util qw(dumper);
use Time::Piece;

has 'pg';

sub add {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $self = shift;
  my $args = @_%2 ? shift : {@_};

  my $template = $args->{template};

  # name => stub
  $template->{stub} //= $template->{name};

  # sanitise name to [A-Za-z0-9_-]
  $template->{stub} =~ s/[^\w-]+//g;

  # ensure we have a stub
  return $cb->('invalid name defined.', undef) unless length $template->{stub};

  my $now = gmtime;

  # generate unique id
  $template->{uuid} = sha256_hex join '',
    $template->{user},
    $template->{name},
    $now->epoch;

  # set default values
  $template->{version}     //= '';
  $template->{description} //= '';
  $template->{includes}    //= [];
  $template->{meta}        //= {};
  $template->{packages}    //= {};
  $template->{repos}       //= {};
  $template->{stores}      //= [];
  $template->{objects}     //= [];

  if ($cb) {
    return Mojo::IOLoop->delay(
      sub {
        my $d = shift;

        # check for existing template
        $self->pg->db->query('
          SELECT t.id
          FROM templates t
          JOIN users u ON
            (u.id=t.owner_id)
          WHERE t.stub=? AND u.username=? AND t.version=?' => ($template->{stub}, $template->{user}, $template->{version}) => $d->begin);
      },
      sub {
        my ($d, $err, $res) = @_;

        # abort on error or results (ie already exists)
        return $cb->('internal server error', undef) if $err;
        return $cb->('template already exists', undef) if $res->rows;

        # insert if we're the owner or member of owner's group
        $self->pg->db->query('
          INSERT INTO templates
            (owner_id, uuid, name, stub, version, description,
            includes, packages, repos, stores, objects, meta)
          SELECT u.id, $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11
          FROM users u
          WHERE
            u.username=$12 AND
            (u.id=$13 OR
              (u.meta->\'members\' @> CAST($13 AS text)::jsonb))
          LIMIT 1' => (
            $template->{uuid},
            $template->{title},
            $template->{stub}, $template->{version},
            $template->{description},
            {json => $template->{includes}},
            {json => $template->{packages}},
            {json => $template->{repos}},
            {json => $template->{stores}},
            {json => $template->{objects}},
            {json => $template->{meta}},
            $template->{user},
            $args->{user_id}
          ) => $d->begin);
      },
      sub {
        my ($d, $err, $res) = @_;

        return $cb->('internal server error', undef) if $err;
        return $cb->('not authorised to add', undef) if $res->rows == 0;

        return $cb->(undef, $template->{uuid});
      }
    );
  }
}

sub all {
  my $self = shift;

  my $args = @_%2 ? shift : {@_};

  return $self->pg->db->query('
    SELECT
      t.id, t.name, t.description, t.stub, t.version, t.includes,
      t.repos, t.packages, t.meta, t.owner_id, u.username AS owner,
      EXTRACT(EPOCH FROM t.created) AS created,
      EXTRACT(EPOCH FROM t.updated) AS updated
    FROM templates t
    JOIN users u ON
      (u.id=t.owner_id)
    WHERE
      (t.owner_id=$1 OR
        (t.meta @> \'{"public": true}\'::jsonb))', $args->{id})->expand->hash;
}

sub find {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $self = shift;

  my $args = @_%2 ? shift : {@_};

  # TODO: page

  if ($cb) {
    return Mojo::IOLoop->delay(
      sub {
        my $d = shift;

        $self->pg->db->query('
          SELECT
            t.uuid, t.name, t.description, t.stub, t.version, t.includes,
            t.repos, t.packages, t.meta, u.username,
            t.stores, t.objects,
            EXTRACT(EPOCH FROM t.created) AS created,
            EXTRACT(EPOCH FROM t.updated) AS updated
          FROM templates t
          JOIN users u ON
            (u.id=t.owner_id)
          WHERE
            (t.uuid=$1 or $1 IS NULL) AND
            (t.stub=$2 or $2 IS NULL) AND
            (t.version=$3 or $3 IS NULL) AND
            (u.username=$4 or $4 IS NULL) AND
            (t.owner_id=$5 OR
              (u.meta->\'members\' @> CAST($5 AS text)::jsonb) OR
              (t.meta @> \'{"public": true}\'::jsonb)
            )
          ORDER BY u.username, t.stub' => (
              $args->{uuid}, $args->{name}, $args->{version},
              $args->{user_name}, $args->{user_id}) => $d->begin);
      },
      sub {
        my ($d, $err, $res) = @_;

        return $cb->('internal server error', undef) if $err;

        return $cb->(undef, $res->expand->hashes);
      }
    );
  }
}

sub get {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $self = shift;
  my $uuid = shift;

  if ($cb) {
    Mojo::IOLoop->delay(
      sub {
        my $d = shift;

        $self->pg->db->query('
          SELECT
            t.uuid, t.name, t.description, t.stub, t.version, t.includes,
            t.repos, t.packages, t.meta, u.username,
            t.stores, t.objects,
            EXTRACT(EPOCH FROM t.created) AS created,
            EXTRACT(EPOCH FROM t.updated) AS updated
          FROM templates t
          JOIN users u ON
            (u.id=t.owner_id)
          WHERE
            t.uuid=$1 LIMIT 1' => ($uuid) => $d->begin);
      },
      sub {
        my ($d, $err, $res) = @_;

        return $cb->('internal server error', undef) if $err;

        return $cb->(undef, $res->expand->hash);
      }
    );
  }
}

sub remove {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $self = shift;
  my $args = @_%2 ? shift : {@_};

  if ($cb) {
    return Mojo::IOLoop->delay(
      sub {
        my $d = shift;

        # check for existing template we can modify/remove
        $self->pg->db->query('
          SELECT t.id
          FROM templates t
          JOIN users u ON
            (u.id=t.owner_id)
          WHERE
            t.uuid=$1 AND
            (u.id=$2 OR (u.meta->\'members\' @> CAST($2 AS text)::jsonb))
          ' => ($args->{uuid}, $args->{user_id}) => $d->begin);
      },
      sub {
        my ($d, $err, $res) = @_;

        # abort on error or results (ie already exists)
        return $cb->('internal server error', undef) if $err;
        return $cb->('template doesn\'t exist', undef) if $res->rows == 0;

        my $id = $res->hash->{id};

        # insert if we're the owner or member of owner's group
        $self->pg->db->query('DELETE FROM templatemeta WHERE template_id=$1' => ($id) => $d->begin);
        $self->pg->db->query('DELETE FROM templates WHERE id=$1' => ($id) => $d->begin);
      },
      sub {
        my ($d, $err_meta, $res_meta, $err, $res) = @_;

        return $cb->('internal server error', undef) if $err or $err_meta;

        return $cb->(undef, $res->rows == 1);
      }
    );
  }
}

sub update {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $self = shift;
  my $args = @_%2 ? shift : {@_};

  my $template = $args->{template};

  # ensure we have a uuid
  return $cb->('no uuid defined.', undef) unless length $template->{uuid};

  # ensure we have a sanitised stub
  $template->{stub} //= $template->{name};
  $template->{stub} =~ s/[^\w-]+//g;
  return $cb->('invalid name defined.', undef) unless length $template->{stub};

  $template->{title}       //= '';
  $template->{version}     //= '';
  $template->{description} //= '';
  $template->{includes}    //= [];
  $template->{meta}        //= {};
  $template->{packages}    //= {};
  $template->{repos}       //= {};
  $template->{stores}      //= [];
  $template->{objects}     //= [];

  if ($cb) {
    return Mojo::IOLoop->delay(
      sub {
        my $d = shift;

        # check for existing template we can modify
        $self->pg->db->query('
          SELECT t.id
          FROM templates t
          JOIN users u ON
            (u.id=t.owner_id)
          WHERE
            t.uuid=$1 AND
            (u.id=$2 OR (u.meta->\'members\' @> CAST($2 AS text)::jsonb))
          ' => ($template->{uuid}, $args->{user_id}) => $d->begin);
      },
      sub {
        my ($d, $err, $res) = @_;

        # abort on error or results (ie already exists)
        return $cb->('internal server error', undef) if $err;
        return $cb->('template doesn\'t exist', undef) if $res->rows == 0;

        # insert if we're the owner or member of owner's group
        $self->pg->db->query('
          UPDATE templates
            SET
              name=$1, stub=$2, version=$3, description=$4,
              includes=$5, packages=$6, repos=$7,
              stores=$8, objects=$9, meta=$10
          WHERE
            uuid=$11' => (
            $template->{title},
            $template->{stub}, $template->{version},
            $template->{description},
            {json => $template->{includes}},
            {json => $template->{packages}},
            {json => $template->{repos}},
            {json => $template->{stores}},
            {json => $template->{objects}},
            {json => $template->{meta}},
            $template->{uuid},
          ) => $d->begin);
      },
      sub {
        my ($d, $err, $res) = @_;

        return $cb->('internal server error', undef) if $err;

        return $cb->(undef, $res->rows == 1);
      }
    );
  }
}

1;
