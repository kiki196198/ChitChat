defmodule ChatApp.FirebaseIdToken do
  @moduledoc "Verifies Firebase Authentication ID tokens issued for this project."

  @cert_url "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"
  @cache_key {__MODULE__, :certificates}

  def verify(token) when is_binary(token) do
    with [encoded_header, encoded_claims, encoded_signature] <- String.split(token, "."),
         {:ok, header} <- decode_json(encoded_header),
         {:ok, claims} <- decode_json(encoded_claims),
         "RS256" <- header["alg"],
         kid when is_binary(kid) <- header["kid"],
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         {:ok, certs} <- certificates(),
         pem when is_binary(pem) <- certs[kid],
         {:ok, public_key} <- public_key(pem),
         true <-
           :public_key.verify(
             "#{encoded_header}.#{encoded_claims}",
             :sha256,
             signature,
             public_key
           ),
         :ok <- validate_claims(claims) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  def verify(_), do: {:error, :invalid_token}

  defp validate_claims(claims) do
    project_id = Application.fetch_env!(:chat_app, :firebase_project_id)
    now = System.system_time(:second)
    firebase = claims["firebase"] || %{}

    valid =
      claims["aud"] == project_id and
        claims["iss"] == "https://securetoken.google.com/#{project_id}" and
        is_binary(claims["sub"]) and byte_size(claims["sub"]) in 1..128 and
        is_binary(claims["email"]) and claims["email_verified"] == true and
        firebase["sign_in_provider"] == "google.com" and
        is_integer(claims["exp"]) and claims["exp"] > now and
        is_integer(claims["iat"]) and claims["iat"] <= now + 60 and
        is_integer(claims["auth_time"]) and claims["auth_time"] <= now + 60

    if valid, do: :ok, else: {:error, :invalid_claims}
  end

  defp decode_json(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, json} <- Jason.decode(decoded) do
      {:ok, json}
    end
  end

  defp public_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    der = elem(entry, 1)
    certificate = :public_key.pkix_decode_cert(der, :otp)
    tbs_certificate = elem(certificate, 1)
    subject_public_key_info = elem(tbs_certificate, 7)
    {:ok, elem(subject_public_key_info, 2)}
  end

  defp certificates do
    now = System.system_time(:second)

    case :persistent_term.get(@cache_key, nil) do
      {expires_at, certs} when expires_at > now ->
        {:ok, certs}

      _ ->
        fetch_certificates(now)
    end
  end

  defp fetch_certificates(now) do
    with {:ok, %{status: 200, body: body, headers: headers}} <-
           Req.get(@cert_url, receive_timeout: 5_000),
         {:ok, certs} when is_map(certs) <- decode_certificates_body(body) do
      max_age = cache_max_age(headers)
      :persistent_term.put(@cache_key, {now + max_age, certs})
      {:ok, certs}
    else
      _ -> {:error, :certificates_unavailable}
    end
  end

  defp decode_certificates_body(body) when is_map(body), do: {:ok, body}
  defp decode_certificates_body(body) when is_binary(body), do: Jason.decode(body)

  defp cache_max_age(headers) do
    value =
      case headers do
        headers when is_map(headers) ->
          headers["cache-control"] || headers["Cache-Control"]

        headers when is_list(headers) ->
          Enum.find_value(headers, fn {key, value} ->
            if String.downcase(key) == "cache-control", do: value
          end)
      end

    value = if is_list(value), do: List.first(value), else: value

    case value && Regex.run(~r/max-age=(\d+)/, value) do
      [_, seconds] -> seconds |> String.to_integer() |> max(60) |> min(86_400)
      _ -> 3_600
    end
  end
end
